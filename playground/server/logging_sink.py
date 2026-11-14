"""Batched, async logger that writes events to ClickHouse Cloud over HTTPS.

Schema + users are bootstrapped on server startup by
`clickhouse_bootstrap.bootstrap()` — see clickhouse-bootstrap.sql for the
canonical DDL of the `requests` (request log + shared queries) and
`events` (operational events) tables and the `request_by_id`
parameterized view. This module only writes; it uses the writer user
issued by the bootstrap, NOT the default user.

When CLICKHOUSE_CLOUD_URL is unset, both tables are mirrored to
/opt/clickbench-playground/logs/requests.jsonl and events.jsonl so the
service still has an audit trail in dev.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import time
from pathlib import Path
from typing import Any

import aiohttp

from .config import Config
from .clickhouse_bootstrap import Credentials

log = logging.getLogger("logging_sink")


class LoggingSink:
    def __init__(self, cfg: Config, creds: Credentials | None):
        self.cfg = cfg
        self._creds = creds
        self._queue: asyncio.Queue[tuple[str, dict]] = asyncio.Queue(maxsize=10000)
        self._task: asyncio.Task | None = None
        self._session: aiohttp.ClientSession | None = None
        self._local_files: dict[str, Path] = {}
        self._enabled = creds is not None

    async def start(self) -> None:
        self.cfg.logs_dir.mkdir(parents=True, exist_ok=True)
        self._local_files = {
            "requests": self.cfg.logs_dir / "requests.jsonl",
            "events":   self.cfg.logs_dir / "events.jsonl",
        }
        if self._enabled:
            self._session = aiohttp.ClientSession()
        self._task = asyncio.create_task(self._flusher(), name="logging-sink")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
        if self._session:
            await self._session.close()

    def write_request(self, **row: Any) -> None:
        self._enqueue("requests", row)

    def write_event(self, **row: Any) -> None:
        self._enqueue("events", row)

    def _enqueue(self, table: str, row: dict) -> None:
        row.setdefault("ts", _now_dt64())
        try:
            self._queue.put_nowait((table, row))
        except asyncio.QueueFull:
            # Backpressure: drop oldest log lines first so we never block the
            # query path on the audit trail.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait((table, row))
            except Exception:
                pass

    async def _exec_ch(self, sql: str) -> None:
        assert self._session is not None and self._creds is not None
        async with self._session.post(
            self._creds.url,
            data=sql,
            auth=aiohttp.BasicAuth(self._creds.writer_user,
                                   self._creds.writer_password),
            timeout=aiohttp.ClientTimeout(total=30),
        ) as r:
            if r.status >= 300:
                txt = await r.text()
                raise RuntimeError(f"CH error {r.status}: {txt[:500]}")

    async def _insert_ch(self, table: str, rows: list[dict]) -> None:
        if not rows or self._creds is None:
            return
        body = "\n".join(json.dumps(r, default=str) for r in rows)
        sql = f"INSERT INTO {self._creds.db}.{table} FORMAT JSONEachRow\n{body}"
        await self._exec_ch(sql)

    async def _flusher(self) -> None:
        buf: dict[str, list[dict]] = {"requests": [], "events": []}
        last_flush = time.monotonic()
        try:
            while True:
                timeout = 1.0
                try:
                    table, row = await asyncio.wait_for(self._queue.get(), timeout=timeout)
                    buf[table].append(row)
                except asyncio.TimeoutError:
                    pass
                # Flush every 1s or when batch >= 256 rows for any table
                now = time.monotonic()
                full = any(len(v) >= 256 for v in buf.values())
                if full or now - last_flush > 1.0:
                    await self._do_flush(buf)
                    for k in buf:
                        buf[k] = []
                    last_flush = now
        except asyncio.CancelledError:
            await self._do_flush(buf)
            raise

    async def _do_flush(self, buf: dict[str, list[dict]]) -> None:
        for table, rows in buf.items():
            if not rows:
                continue
            # Always write to the local JSONL too — gives us a tail for
            # debugging and a buffer if CH Cloud rejects.
            try:
                with open(self._local_files[table], "ab") as f:
                    for r in rows:
                        f.write((json.dumps(r, default=str) + "\n").encode())
            except Exception:
                pass
            if self._enabled:
                try:
                    await self._insert_ch(table, rows)
                except Exception as e:
                    log.warning("CH insert failed (%r); rows preserved in JSONL", e)


def _now_dt64() -> str:
    t = time.time()
    return time.strftime("%Y-%m-%d %H:%M:%S.", time.gmtime(t)) + f"{int((t % 1) * 1e6):06d}"
