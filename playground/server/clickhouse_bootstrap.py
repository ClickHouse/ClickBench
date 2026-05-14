"""ClickHouse bootstrap: schema + writer/reader users.

Runs on server startup using the default-user credentials supplied in
<state_dir>/clickhouse.conf (or env vars). Idempotent:

* Schema DDL (DB + tables + parameterized view) lives in the sibling
  clickhouse-bootstrap.sql file — that file is the canonical source
  of truth for the request/event tables and the request_by_id view.
* The two human users are created here in Python because CREATE USER
  doesn't accept HTTP query parameters for the password / host clauses
  and rotating those at bootstrap time is convenient.

Generated credentials persist to <state_dir>/clickhouse-credentials.json
so the writer/reader users keep the same password across restarts; if
the file is missing, fresh random passwords are generated and the
users' passwords are reset to match.
"""
from __future__ import annotations

import contextlib
import json
import logging
import secrets
from pathlib import Path
from typing import NamedTuple
from urllib.parse import urlencode

import aiohttp

from .config import Config

log = logging.getLogger("clickhouse_bootstrap")

_SQL_FILE = Path(__file__).parent / "clickhouse-bootstrap.sql"


class Credentials(NamedTuple):
    url: str
    db: str
    writer_user: str
    writer_password: str
    reader_user: str
    reader_password: str


def _gen_pw(n: int = 32) -> str:
    # URL-safe random string. Avoid characters that need escaping in
    # SQL literals.
    return secrets.token_urlsafe(n)


def _credentials_path(cfg: Config) -> Path:
    return cfg.state_dir / "clickhouse-credentials.json"


def _load_or_make_credentials(cfg: Config) -> tuple[str, str]:
    """Return (writer_password, reader_password). Persist on first run."""
    path = _credentials_path(cfg)
    if path.exists():
        with contextlib.suppress(Exception):
            data = json.loads(path.read_text())
            return data["writer_password"], data["reader_password"]
    creds = {
        "writer_password": _gen_pw(),
        "reader_password": _gen_pw(),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(creds, indent=2))
    path.chmod(0o600)
    return creds["writer_password"], creds["reader_password"]


async def _ch_exec(session: aiohttp.ClientSession,
                   url: str, user: str, password: str,
                   sql: str, params: dict[str, str] | None = None) -> str:
    """Run `sql` via HTTP and return the response body. Raises on
    non-2xx."""
    qs = {f"param_{k}": v for k, v in (params or {}).items()}
    full = url + ("?" + urlencode(qs) if qs else "")
    async with session.post(
        full, data=sql,
        auth=aiohttp.BasicAuth(user, password),
        timeout=aiohttp.ClientTimeout(total=60),
    ) as r:
        body = await r.text()
        if r.status >= 300:
            raise RuntimeError(f"CH bootstrap {r.status}: {body[:500]} (sql={sql[:200]})")
        return body


async def bootstrap(cfg: Config) -> Credentials | None:
    """Run the bootstrap. Returns the credentials the runtime should
    use for the writer (logging sink) and the reader (saved-query
    lookups). Returns None if the bootstrap config isn't present
    (CH integration disabled)."""
    if not (cfg.ch_cloud_url and cfg.ch_cloud_user and cfg.ch_cloud_password):
        return None
    db = cfg.ch_cloud_db or "playground"
    writer_pw, reader_pw = _load_or_make_credentials(cfg)
    async with aiohttp.ClientSession() as session:
        # Find the IP CH Cloud sees us connecting from — that's the
        # host the writer user is restricted to.
        body = await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            "SELECT toString(remote_address())",
        )
        # CH returns "ip:port\n"; strip the port.
        writer_host = body.strip().split(":")[0]

        # Schema DDL from the .sql file. Each statement runs in its
        # own request so server-side parameter substitution works.
        sql_blob = _SQL_FILE.read_text()
        # Strip line comments and split on `;` boundaries.
        statements = _split_sql_statements(sql_blob)
        for stmt in statements:
            await _ch_exec(
                session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
                stmt, params={"db": db},
            )

        # Users — passwords + host clause go inline; ALTER on every
        # bootstrap rotates / re-pins them.
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"CREATE USER IF NOT EXISTS playground_writer "
            f"IDENTIFIED WITH sha256_password BY '{writer_pw}' "
            f"HOST IP '{writer_host}'",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"ALTER USER playground_writer "
            f"IDENTIFIED WITH sha256_password BY '{writer_pw}' "
            f"HOST IP '{writer_host}'",
        )
        # Strict scope: revoke everything then re-grant only INSERT.
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"REVOKE ALL ON *.* FROM playground_writer",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"GRANT INSERT ON {db}.requests TO playground_writer",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"GRANT INSERT ON {db}.events TO playground_writer",
        )

        # Reader: public, SELECT-only on the parameterized view, with
        # tight resource caps. Profile-style settings prevent anyone
        # who somehow gets the password from using it as a foothold.
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"CREATE USER IF NOT EXISTS playground_reader "
            f"IDENTIFIED WITH sha256_password BY '{reader_pw}' "
            f"DEFAULT DATABASE {db} "
            f"SETTINGS readonly = 2, "
            f"max_execution_time = 5, "
            f"max_memory_usage = 100000000, "
            f"max_result_rows = 1, "
            f"max_rows_to_read = 1048576, "
            f"max_threads = 2",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"ALTER USER playground_reader "
            f"IDENTIFIED WITH sha256_password BY '{reader_pw}'",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"REVOKE ALL ON *.* FROM playground_reader",
        )
        await _ch_exec(
            session, cfg.ch_cloud_url, cfg.ch_cloud_user, cfg.ch_cloud_password,
            f"GRANT SELECT ON {db}.request_by_id TO playground_reader",
        )

    log.info("ClickHouse bootstrap complete (writer host=%s)", writer_host)
    return Credentials(
        url=cfg.ch_cloud_url, db=db,
        writer_user="playground_writer", writer_password=writer_pw,
        reader_user="playground_reader", reader_password=reader_pw,
    )


def _split_sql_statements(blob: str) -> list[str]:
    """Strip --line comments, split on top-level `;`. Naive — fine for
    the bootstrap file which has no string literals or nested blocks."""
    stripped = "\n".join(
        line for line in blob.splitlines()
        if not line.lstrip().startswith("--")
    )
    return [s.strip() for s in stripped.split(";") if s.strip()]
