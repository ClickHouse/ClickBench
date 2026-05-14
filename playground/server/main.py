"""Playground HTTP API + static UI server.

Endpoints:

    GET  /                     redirects to /ui/
    GET  /ui/...               static-serves files from ../web/
    GET  /api/systems          JSON list of all playground-eligible systems
    GET  /api/state            JSON snapshot of every VM's state
    GET  /api/system/{name}    detail for a single system
    POST /api/query?system=X   body is the SQL; returns application/octet-stream
                               with timing in headers
    GET  /api/provision-log/{name}  the system's most recent provision log
    POST /api/admin/provision/{name}
                               manual trigger for first-time provision; convenient
                               for warming a system before the first user query

The /api/query path tries once, then on failure tears down + restores from
snapshot and retries exactly once, matching the spec.
"""
from __future__ import annotations

import asyncio
import base64
import contextlib
import logging
import signal
import time
import urllib.parse


def _id_to_b64url(n: int) -> str:
    """64-bit unsigned int -> 11-char URL-safe base64 (no padding).
    Symmetric counterpart to _b64url_to_id. The same number can travel
    as a UInt64 inside ClickHouse and as a tidy URL handle."""
    return base64.urlsafe_b64encode(
        n.to_bytes(8, "big"),
    ).rstrip(b"=").decode("ascii")


def _b64url_to_id(s: str) -> int:
    pad = "=" * (-len(s) % 4)
    return int.from_bytes(base64.urlsafe_b64decode(s + pad), "big")
from pathlib import Path

import collections
import threading

import aiohttp
from aiohttp import web

# --- Per-IP rate limiting ------------------------------------------
#
# /api/query and /api/warmup are unauthenticated; a single bad actor
# can wedge the playground by spamming restores or kicking heavy
# queries against snapshotted systems. Bound the damage with two
# rolling windows per source IP:
#   200 requests / minute
#   3000 requests / hour
# In-memory, since restarts are infrequent and per-IP state across
# restarts isn't load-bearing for this use case.
_RATE_PER_MINUTE = 200
_RATE_PER_HOUR = 3000
_rate_lock = threading.Lock()
_rate_hits: dict[str, collections.deque[float]] = {}


def _client_ip(req: web.Request) -> str:
    """TCP peer address — never the X-Forwarded-For header. Honoring
    XFF without an authenticated reverse proxy in front would let any
    caller spoof their IP and bypass the rate limit by rotating the
    header value."""
    return req.remote or "?"


def _rate_check(req: web.Request) -> web.Response | None:
    """Return a 429 Response if the caller has exceeded either window,
    else None. Increments the counter on a pass."""
    ip = _client_ip(req)
    now = time.monotonic()
    hour_ago = now - 3600
    minute_ago = now - 60
    with _rate_lock:
        dq = _rate_hits.get(ip)
        if dq is None:
            dq = collections.deque()
            _rate_hits[ip] = dq
        # Trim timestamps older than 1 hour. The deque is sorted
        # because we only ever append `now`, so popping from the left
        # is O(1) per stale entry.
        while dq and dq[0] < hour_ago:
            dq.popleft()
        if len(dq) >= _RATE_PER_HOUR:
            retry = max(1, int(dq[0] + 3600 - now))
            return web.json_response(
                {"error": "rate limit (hour)",
                 "limit": _RATE_PER_HOUR, "retry_after": retry},
                status=429, headers={"Retry-After": str(retry)},
            )
        recent = sum(1 for t in dq if t >= minute_ago)
        if recent >= _RATE_PER_MINUTE:
            # Find oldest sample inside the 1-minute window to suggest
            # a reasonable retry-after.
            oldest_in_min = next(t for t in dq if t >= minute_ago)
            retry = max(1, int(oldest_in_min + 60 - now))
            return web.json_response(
                {"error": "rate limit (minute)",
                 "limit": _RATE_PER_MINUTE, "retry_after": retry},
                status=429, headers={"Retry-After": str(retry)},
            )
        dq.append(now)
        # Occasional GC: if a deque ever empties (unlikely under live
        # load but possible for one-shot IPs), let it linger one cycle
        # then drop. We do the drop opportunistically on insert.
        if len(_rate_hits) > 10000:
            # Pathological: 10k+ distinct IPs in the last hour. Evict
            # entries whose newest hit is > 1h ago.
            for stale_ip in [k for k, d in _rate_hits.items() if not d]:
                _rate_hits.pop(stale_ip, None)
    return None


# Refuse to start on aiohttp versions vulnerable to the static-handler
# path traversal (GHSA-5h86-8mv2-jq9f, fixed in 3.9.2) and the HTTP
# request-smuggling fixes that landed in 3.9.x / 3.10.x. We mitigate
# follow_symlinks at the call site too, but a runtime guard catches
# any future regression where someone re-enables it under an old lib.
_AIOHTTP_MIN = (3, 10, 0)
_aiohttp_v = tuple(int(p) for p in aiohttp.__version__.split(".")[:3]
                   if p.isdigit())
if _aiohttp_v < _AIOHTTP_MIN:
    raise RuntimeError(
        f"aiohttp {aiohttp.__version__} is too old; "
        f"require >= {'.'.join(str(x) for x in _AIOHTTP_MIN)} "
        "(GHSA-5h86-8mv2-jq9f and request-smuggling fixes)"
    )

from . import config as config_mod
from . import net
from . import systems as systems_mod
from .logging_sink import LoggingSink
from .monitor import Monitor
from .vm_manager import VMManager

log = logging.getLogger("playground")


class App:
    def __init__(self) -> None:
        self.cfg = config_mod.load()
        self.systems = systems_mod.discover(self.cfg.repo_dir)
        self.vmm = VMManager(self.cfg, self.systems)
        # CH credentials are populated by on_startup after the
        # bootstrap runs. None means CH integration is disabled and
        # the sink falls back to JSONL.
        self.ch_creds = None
        self.sink = LoggingSink(self.cfg, None)
        self.monitor = Monitor(self.cfg, self.vmm, self.sink)

    async def on_startup(self, _app: web.Application) -> None:
        from . import clickhouse_bootstrap
        try:
            self.ch_creds = await clickhouse_bootstrap.bootstrap(self.cfg)
        except Exception as e:
            log.warning("ClickHouse bootstrap failed (%r); CH integration disabled", e)
            self.ch_creds = None
        # Replace the placeholder sink with one wired to the bootstrap's
        # writer credentials.
        self.sink = LoggingSink(self.cfg, self.ch_creds)
        self.monitor.sink = self.sink
        await self.sink.start()
        await self.monitor.start()
        # SNI-allowlist proxy that mediates outbound HTTP/HTTPS for
        # *-datalake systems (see net.enable_filtered_internet).
        from . import sni_proxy
        self.sni_servers = await sni_proxy.start(
            https_port=net.PROXY_HTTPS_PORT,
            http_port=net.PROXY_HTTP_PORT,
        )
        # Lock the proxy + local DNS resolver to internal/VM traffic
        # only. The proxy binds 0.0.0.0 so iptables PREROUTING REDIRECT
        # from each TAP can find it; without these INPUT rules it
        # would be an open S3 allowlist relay on the public internet.
        await net.setup_host_firewall()

    async def on_cleanup(self, _app: web.Application) -> None:
        await self.monitor.stop()
        await self.sink.stop()
        for s in getattr(self, "sni_servers", []):
            s.close()
            with contextlib.suppress(Exception):
                await s.wait_closed()

    # ── handlers ─────────────────────────────────────────────────────────

    async def handle_systems(self, _r: web.Request) -> web.Response:
        return web.json_response([s.asdict() for s in self.systems.values()])

    async def handle_state(self, _r: web.Request) -> web.Response:
        return web.json_response(self.vmm.list_all())

    async def handle_system(self, req: web.Request) -> web.Response:
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound(reason=f"unknown system: {name}")
        vm = self.vmm.vms[name]
        return web.json_response({
            **self.systems[name].asdict(),
            "state": vm.state,
            "has_snapshot": vm.snapshot_bin.exists(),
            "provisioned_at": vm.provisioned_at,
            "last_used": vm.last_used,
            "ready_since": vm.ready_since,
            "last_error": vm.last_error,
            "agent_url": self.vmm.agent_url(vm),
        })

    async def handle_queries(self, req: web.Request) -> web.Response:
        """Return example queries for a system from its queries.sql.

        Splits by lines: one example per non-empty, non-comment line.
        ClickBench's benchmark files are uniformly one-query-per-line —
        SQL ones end with `;`, dataframe ones (pandas/polars/daft) and
        LogsQL ones (victorialogs) don't, and a `;\n` splitter collapsed
        the whole pandas file into one entry. Truncates to 200 entries.
        """
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        path = self.cfg.repo_dir / name / "queries.sql"
        if not path.exists():
            return web.json_response([])
        text = path.read_text(errors="replace")
        out = []
        for line in text.splitlines():
            q = line.strip()
            if not q or q.startswith("--") or q.startswith("#"):
                continue
            out.append(q)
            if len(out) >= 200:
                break
        return web.json_response(out)

    async def handle_provision_log(self, req: web.Request) -> web.Response:
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        log_path = self.cfg.logs_dir / f"firecracker-{name}.log"
        if not log_path.exists():
            return web.Response(text="", content_type="text/plain")
        try:
            # Tail at most 64 KB so the browser doesn't choke.
            data = log_path.read_bytes()[-64 * 1024:]
        except Exception as e:
            data = f"(failed to read: {e})".encode()
        return web.Response(body=data, content_type="text/plain")

    async def handle_admin_provision(self, req: web.Request) -> web.Response:
        # Heavy operation (re-runs install/start/load, can take hours on
        # the postgres-indexed-class systems): only callable from the
        # host itself. The public UI must never be able to trigger this.
        # Trust the TCP peer address — we don't honor X-Forwarded-For
        # here, because the server is meant to listen on the same host
        # the operator drives the curls from. If you put it behind a
        # reverse proxy, the proxy itself becomes the peer and the
        # check still passes (which is fine: the proxy is part of the
        # admin trust boundary).
        peer = req.transport.get_extra_info("peername") if req.transport else None
        peer_ip = peer[0] if peer else ""
        if peer_ip not in ("127.0.0.1", "::1"):
            raise web.HTTPForbidden(reason="admin endpoint, loopback only")
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        # Fire-and-forget; the client polls /api/system/{name} for state.
        asyncio.create_task(self._provision_bg(name))
        return web.json_response({"started": True, "system": name})

    async def _provision_bg(self, name: str) -> None:
        try:
            await self.vmm.provision_now(name)
        except Exception as e:
            log.exception("background provision failed for %s", name)
            self.sink.write_event(system=name, kind="provision-failed", detail=repr(e))

    async def handle_warmup(self, req: web.Request) -> web.Response:
        """Trigger snapshot restore for a system without running a query.

        The UI calls this on system-select so the restore (~30 s for
        cold ones, near-zero with reflink+live-daemon) overlaps the
        time the user is typing their query, and Run query lands on a
        VM that's already serving. Refuses to initial-provision; if no
        snapshot exists, returns 409 and the user has to /admin/provision.
        """
        if (resp := _rate_check(req)) is not None:
            return resp
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        vm = self.vmm.vms[name]
        if vm.state == "ready":
            return web.json_response({"already_ready": True, "system": name})
        if vm.state == "provisioning":
            return web.json_response({"in_flight": True, "system": name})
        if not self.vmm.vms[name].snapshot_bin.exists() and \
           not (self.cfg.systems_dir / name / "rootfs.golden.ext4").exists():
            return web.json_response(
                {"error": "no snapshot; POST /api/admin/provision first"},
                status=409,
            )
        asyncio.create_task(self._warmup_bg(name))
        return web.json_response({"started": True, "system": name})

    async def _warmup_bg(self, name: str) -> None:
        try:
            await self.vmm.ensure_ready_for_query(name)
        except Exception as e:
            log.warning("warmup failed for %s: %r", name, e)

    async def handle_query(self, req: web.Request) -> web.StreamResponse:
        if (resp := _rate_check(req)) is not None:
            return resp
        system_name = req.query.get("system", "")
        if system_name not in self.systems:
            return web.json_response({"error": f"unknown system: {system_name!r}"},
                                     status=400)
        sql = await req.read()
        if not sql.strip():
            return web.json_response({"error": "empty SQL"}, status=400)

        client_addr = req.headers.get("X-Forwarded-For", req.remote or "?")
        ua = req.headers.get("User-Agent", "")
        wall_t0 = time.monotonic()
        status = 500
        body = b""
        headers: dict[str, str] = {}
        err: str | None = None
        # Random 64-bit handle returned to the client as a base64url
        # string (X-Query-Id) AND persisted to the requests table.
        # The same id is the key the browser uses to permalink the
        # result via /api/saved/<id>.
        import secrets
        query_id = secrets.randbits(64)
        try:
            body, headers, status = await self._dispatch_query(system_name, sql)
        except Exception as e:
            err = repr(e)
            log.exception("[%s] query dispatch failed", system_name)
        finally:
            wall = time.monotonic() - wall_t0
            try:
                self.sink.write_request(
                    id=query_id,
                    client_addr=client_addr, user_agent=ua,
                    system=system_name,
                    query=sql.decode("utf-8", errors="replace")[:65536],
                    output=body.decode("utf-8", errors="replace")[:1 << 20],
                    output_bytes=int(headers.get("X-Output-Bytes", "0") or 0),
                    output_truncated=int(headers.get("X-Output-Truncated", "0") or 0),
                    query_time=(float(headers["X-Query-Time"])
                                if "X-Query-Time" in headers else None),
                    wall_time=wall,
                    status=status,
                    # The agent URL-encodes X-Error so newlines survive
                    # the HTTP header. Decode before logging so the
                    # ClickHouse log stores the raw multi-line error.
                    error=err or urllib.parse.unquote(
                        headers.get("X-Error", "")),
                )
            except Exception:
                log.exception("logging request failed")

        resp = web.Response(body=body, status=status,
                            content_type="application/octet-stream")
        for k, v in headers.items():
            resp.headers[k] = v
        resp.headers["X-Wall-Time"] = f"{wall:.6f}"
        resp.headers["X-Query-Id"] = _id_to_b64url(query_id)
        if err and "X-Error" not in resp.headers:
            # URL-encode to match the agent path so the client always
            # decodes uniformly. err is usually a one-liner, so this
            # is a no-op in practice; but keeps the contract simple.
            resp.headers["X-Error"] = urllib.parse.quote(err[:512])
        return resp

    async def handle_saved(self, req: web.Request) -> web.Response:
        """Look up a previously-saved query+result by its base64url id.
        Returns a JSON object with output, error, timing — the browser
        replays it as if the query just ran.
        """
        if self.ch_creds is None:
            raise web.HTTPServiceUnavailable(reason="shared queries disabled (no CH)")
        b64 = req.match_info["b64"]
        try:
            qid = _b64url_to_id(b64)
        except Exception:
            raise web.HTTPBadRequest(reason="malformed id")
        # Read through the parameterized view as the reader user. The
        # view has SQL SECURITY DEFINER so the reader doesn't need a
        # direct grant on the requests table.
        sql = (f"SELECT * FROM {self.ch_creds.db}.request_by_id(q_id={qid}) "
               f"FORMAT JSONEachRow")
        async with aiohttp.ClientSession() as s:
            async with s.post(
                self.ch_creds.url, data=sql,
                auth=aiohttp.BasicAuth(self.ch_creds.reader_user),
                timeout=aiohttp.ClientTimeout(total=10),
            ) as r:
                text = await r.text()
                if r.status >= 300:
                    raise web.HTTPBadGateway(reason=f"ch {r.status}: {text[:300]}")
        text = text.strip()
        if not text:
            raise web.HTTPNotFound(reason="no saved query with that id")
        return web.Response(text=text, content_type="application/json")

    async def _dispatch_query(self, system_name: str, sql: bytes
                              ) -> tuple[bytes, dict[str, str], int]:
        """Run the query once. On low-level failure (VM unreachable, transport
        error) tear down and retry once. Higher-level errors (non-2xx from the
        agent itself, e.g. a SQL syntax error) are NOT retried — they're real
        results."""
        last_exc: Exception | None = None
        for attempt in (1, 2):
            try:
                vm = await self.vmm.ensure_ready_for_query(system_name)
            except Exception as e:
                last_exc = e
                if attempt == 1:
                    self.sink.write_event(system=system_name, kind="ensure-failed",
                                          detail=f"attempt {attempt}: {e!r}")
                    await asyncio.sleep(0.5)
                    continue
                raise
            url = self.vmm.agent_url(vm) + "/query"
            try:
                async with aiohttp.ClientSession() as s:
                    async with s.post(url, data=sql,
                                      timeout=aiohttp.ClientTimeout(total=60)) as r:
                        body = await r.read()
                        headers = {k: r.headers[k] for k in r.headers if k.startswith("X-")}
                        headers.setdefault("X-Output-Bytes", str(len(body)))
                        if r.status >= 400:
                            # ANY error tears the VM down so the next
                            # request restores from snapshot. The
                            # playground accepts destructive SQL
                            # (DROP TABLE hits, TRUNCATE, ...) — once
                            # an error happens we can't be sure the
                            # daemon's state is still consistent, so
                            # the safe move is always to reset.
                            self.sink.write_event(
                                system=system_name, kind="post-query-error",
                                detail=f"attempt {attempt}: status={r.status}",
                            )
                            await self.vmm.kick(system_name,
                                                "post-query-error")
                        return body, headers, r.status
            except Exception as e:
                last_exc = e
                self.sink.write_event(system=system_name, kind="agent-error",
                                      detail=f"attempt {attempt}: {e!r}")
                if attempt == 1:
                    # Hard kill, will trigger snapshot restore on next ensure.
                    await self.vmm.kick(system_name, "agent-error-retry")
                    await asyncio.sleep(0.5)
                    continue
                raise
        # unreachable, but keep mypy happy
        raise RuntimeError(str(last_exc))

def build_app() -> web.Application:
    obj = App()
    app = web.Application(client_max_size=4 * 1024 * 1024)
    app.on_startup.append(obj.on_startup)
    app.on_cleanup.append(obj.on_cleanup)

    app.router.add_get("/api/systems", obj.handle_systems)
    app.router.add_get("/api/state", obj.handle_state)
    app.router.add_get("/api/system/{name}", obj.handle_system)
    app.router.add_get("/api/queries/{name}", obj.handle_queries)
    app.router.add_get("/api/provision-log/{name}", obj.handle_provision_log)
    app.router.add_post("/api/admin/provision/{name}", obj.handle_admin_provision)
    app.router.add_post("/api/warmup/{name}", obj.handle_warmup)
    app.router.add_post("/api/query", obj.handle_query)
    app.router.add_get("/api/saved/{b64}", obj.handle_saved)

    # Static UI
    web_dir = Path(__file__).resolve().parent.parent / "web"

    async def root_redirect(_r: web.Request) -> web.Response:
        raise web.HTTPFound("/ui/")

    async def ui_index(_r: web.Request) -> web.FileResponse:
        resp = web.FileResponse(web_dir / "index.html")
        resp.headers["Cache-Control"] = "no-store"
        return resp

    @web.middleware
    async def no_cache_static(request: web.Request, handler):
        resp = await handler(request)
        if request.path.startswith("/ui/"):
            resp.headers["Cache-Control"] = "no-store"
        return resp

    @web.middleware
    async def cors(request: web.Request, handler):
        # Permit the index.html opened from file:// (or any other origin)
        # to call /api/* directly. The browser sends Origin: null in that
        # case and refuses the response without ACAO. Reflecting the
        # request's Origin keeps credentials-less CORS working in every
        # browser. Preflight OPTIONS gets a synthetic 204 here.
        origin = request.headers.get("Origin", "*")
        if request.method == "OPTIONS":
            return web.Response(status=204, headers={
                "Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers":
                    request.headers.get("Access-Control-Request-Headers", "*"),
                "Access-Control-Max-Age": "86400",
            })
        resp = await handler(request)
        resp.headers["Access-Control-Allow-Origin"] = origin
        resp.headers["Access-Control-Expose-Headers"] = (
            "X-Query-Time, X-Wall-Time, X-Query-Wall-Time, "
            "X-Output-Bytes, X-Output-Truncated, X-Exit-Code, "
            "X-System, X-Error, X-Query-Id"
        )
        return resp

    app.middlewares.append(no_cache_static)
    app.middlewares.append(cors)
    app.router.add_get("/", root_redirect)
    app.router.add_get("/ui/", ui_index)
    app.router.add_get("/ui", ui_index)
    # follow_symlinks=False — GHSA-5h86-8mv2-jq9f covers a path-traversal
    # in aiohttp's static handler that's only reachable when symlinks are
    # followed. The repo's web/ tree has no symlinks anyway.
    app.router.add_static("/ui/", path=str(web_dir), show_index=False)

    return app


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    cfg = config_mod.load()
    app = build_app()
    # Wire signals to a clean shutdown.
    runner = web.AppRunner(app)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    loop.run_until_complete(runner.setup())
    site = web.TCPSite(runner, cfg.listen_host, cfg.listen_port)
    loop.run_until_complete(site.start())
    log.info("playground listening on http://%s:%d", cfg.listen_host, cfg.listen_port)

    stop = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    loop.run_until_complete(stop.wait())
    loop.run_until_complete(runner.cleanup())
    loop.close()


if __name__ == "__main__":
    main()
