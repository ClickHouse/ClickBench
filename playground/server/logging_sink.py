"""Batched, async logger that writes events to ClickHouse Cloud over HTTPS.

Two tables (auto-created on first connect if writeable):

  playground.requests
    ts                  DateTime64(6)
    client_addr         String
    user_agent          String
    system              String
    query               String
    output_bytes        UInt64
    output_truncated    UInt8
    query_time          Nullable(Float64)   from agent X-Query-Time
    wall_time           Float64             host-side end-to-end
    status              UInt16              HTTP status returned to client
    error               String

  playground.events
    ts                  DateTime64(6)
    system              String
    kind                String              "restart" / "oom-kick" / "boot" / ...
    detail              String

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

log = logging.getLogger("logging_sink")


_REQUESTS_DDL = """
CREATE TABLE IF NOT EXISTS playground.requests (
    ts                DateTime64(6) DEFAULT now64(6),
    client_addr       String,
    user_agent        String,
    system            String,
    query             String,
    output_bytes      UInt64,
    output_truncated  UInt8,
    query_time        Nullable(Float64),
    wall_time         Float64,
    status            UInt16,
    error             String
) ENGINE = MergeTree ORDER BY (system, ts)
"""

_EVENTS_DDL = """
CREATE TABLE IF NOT EXISTS playground.events (
    ts      DateTime64(6) DEFAULT now64(6),
    system  String,
    kind    String,
    detail  String
) ENGINE = MergeTree ORDER BY (system, ts)
"""


class LoggingSink:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self._queue: asyncio.Queue[tuple[str, dict]] = asyncio.Queue(maxsize=10000)
        self._task: asyncio.Task | None = None
        self._session: aiohttp.ClientSession | None = None
        self._local_files: dict[str, Path] = {}
        self._enabled = bool(cfg.ch_cloud_url and cfg.ch_cloud_user and cfg.ch_cloud_password)

    async def start(self) -> None:
        self.cfg.logs_dir.mkdir(parents=True, exist_ok=True)
        self._local_files = {
            "requests": self.cfg.logs_dir / "requests.jsonl",
            "events":   self.cfg.logs_dir / "events.jsonl",
        }
        if self._enabled:
            try:
                self._session = aiohttp.ClientSession()
                await self._run_ddl()
            except Exception as e:
                log.warning("ClickHouse Cloud DDL failed (%r); falling back to JSONL only", e)
                self._enabled = False
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

    async def _run_ddl(self) -> None:
        await self._exec_ch(f"CREATE DATABASE IF NOT EXISTS {self.cfg.ch_cloud_db}")
        await self._exec_ch(_REQUESTS_DDL.replace("playground.", f"{self.cfg.ch_cloud_db}."))
        await self._exec_ch(_EVENTS_DDL.replace("playground.", f"{self.cfg.ch_cloud_db}."))

    async def _exec_ch(self, sql: str) -> None:
        assert self._session is not None
        async with self._session.post(
            self.cfg.ch_cloud_url,
            data=sql,
            auth=aiohttp.BasicAuth(self.cfg.ch_cloud_user, self.cfg.ch_cloud_password),
            timeout=aiohttp.ClientTimeout(total=30),
        ) as r:
            if r.status >= 300:
                txt = await r.text()
                raise RuntimeError(f"CH error {r.status}: {txt[:500]}")

    async def _insert_ch(self, table: str, rows: list[dict]) -> None:
        if not rows:
            return
        body = "\n".join(json.dumps(r, default=str) for r in rows)
        sql = f"INSERT INTO {self.cfg.ch_cloud_db}.{table} FORMAT JSONEachRow\n{body}"
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
