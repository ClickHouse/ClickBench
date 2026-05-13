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
import logging
import signal
import time
from pathlib import Path

import aiohttp
from aiohttp import web

from . import config as config_mod
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
        self.sink = LoggingSink(self.cfg)
        self.monitor = Monitor(self.cfg, self.vmm, self.sink)

    async def on_startup(self, _app: web.Application) -> None:
        await self.sink.start()
        await self.monitor.start()

    async def on_cleanup(self, _app: web.Application) -> None:
        await self.monitor.stop()
        await self.sink.stop()

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

        Splits on `;\n` so multi-line queries stay together. Truncates to
        a sane upper bound — ClickBench has 43 per system, no need to
        cap, but if a fork ships thousands we don't want to ship them
        all to the browser.
        """
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        path = self.cfg.repo_dir / name / "queries.sql"
        if not path.exists():
            return web.json_response([])
        text = path.read_text(errors="replace")
        # Split on `;\n` then trim. Drop empties.
        out = []
        for chunk in text.split(";\n"):
            q = chunk.strip()
            if not q:
                continue
            if not q.endswith(";"):
                q += ";"
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
        name = req.match_info["name"]
        if name not in self.systems:
            raise web.HTTPNotFound()
        # Fire-and-forget; the client polls /api/system/{name} for state.
        asyncio.create_task(self._provision_bg(name))
        return web.json_response({"started": True, "system": name})

    async def _provision_bg(self, name: str) -> None:
        try:
            await self.vmm.ensure_ready_for_query(name)
        except Exception as e:
            log.exception("background provision failed for %s", name)
            self.sink.write_event(system=name, kind="provision-failed", detail=repr(e))

    async def handle_query(self, req: web.Request) -> web.StreamResponse:
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
        try:
            body, headers, status = await self._dispatch_query(system_name, sql)
        except Exception as e:
            err = repr(e)
            log.exception("[%s] query dispatch failed", system_name)
        finally:
            wall = time.monotonic() - wall_t0
            try:
                self.sink.write_request(
                    client_addr=client_addr, user_agent=ua,
                    system=system_name,
                    query=sql.decode("utf-8", errors="replace")[:65536],
                    output_bytes=int(headers.get("X-Output-Bytes", "0") or 0),
                    output_truncated=int(headers.get("X-Output-Truncated", "0") or 0),
                    query_time=(float(headers["X-Query-Time"])
                                if "X-Query-Time" in headers else None),
                    wall_time=wall,
                    status=status,
                    error=err or "",
                )
            except Exception:
                log.exception("logging request failed")

        resp = web.Response(body=body, status=status,
                            content_type="application/octet-stream")
        for k, v in headers.items():
            resp.headers[k] = v
        resp.headers["X-Wall-Time"] = f"{wall:.6f}"
        if err and "X-Error" not in resp.headers:
            resp.headers["X-Error"] = err[:512]
        return resp

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
    app.router.add_post("/api/query", obj.handle_query)

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

    app.middlewares.append(no_cache_static)
    app.router.add_get("/", root_redirect)
    app.router.add_get("/ui/", ui_index)
    app.router.add_get("/ui", ui_index)
    app.router.add_static("/ui/", path=str(web_dir), show_index=False, follow_symlinks=True)

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
