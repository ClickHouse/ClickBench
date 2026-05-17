#!/usr/bin/env python3
"""Parallel JSON-over-HTTP loader for EventQL.

EventQL has no bulk-CSV import (upstream issue #365). The only documented
ingest path is `POST /api/v1/tables/insert` with a JSON array of row
objects. The body shape, taken straight from upstream's mysql2evql tool:

    [
      {"database": "clickbench",
       "table": "hits",
       "data": {"col": "val", ...}},
      ...
    ]

This script reads hits.tsv on stdin and drives N concurrent POSTers
against the daemon. Each request carries SHARD rows. Defaults
(32 workers x 1000 rows/batch) push the parser/HTTP layer hard enough
to land under the 10h benchmark timeout for the 100M-row dataset; the
naive single-threaded mysql2evql defaults (8 x 128) hit a ~10h wall
even on a fast box.

Notes:
- All values are stringified before serialisation. EventQL's insert
  handler accepts strings for every column type (it parses them
  server-side per the table schema), and going through plain strings
  sidesteps issues with the TSV's mixed numeric/textual columns.
- Empty TSV fields become empty strings. EventQL coerces empty into the
  type's zero value for NOT NULL columns and into NULL for nullable
  columns, which matches the ClickBench data's intent.
- DATETIME values must be ISO-8601-ish. The TSV stores Unix epoch
  seconds (EventTime, ClientEventTime, LocalEventTime) and YYYY-MM-DD
  (EventDate). We pre-format here so the server doesn't reject the row.
- Retries: each batch is retried up to RETRIES times with linear
  backoff; permanent failures are logged and counted, then the loader
  continues. A single bad row shouldn't abort a 100M-row load.
"""
import asyncio
import json
import os
import sys
import time
from datetime import datetime, timezone

import aiohttp

URL = os.environ.get("EVQL_URL", "http://127.0.0.1:9175/api/v1/tables/insert")
DB = os.environ.get("EVQL_DB", "clickbench")
TABLE = os.environ.get("EVQL_TABLE", "hits")
WORKERS = int(os.environ.get("EVQL_WORKERS", "32"))
SHARD = int(os.environ.get("EVQL_SHARD", "1000"))
RETRIES = int(os.environ.get("EVQL_RETRIES", "10"))

# The 105 column names in the order they appear in hits.tsv. Must match
# create.sql exactly. Sourced from clickhouse/queries.sql / the dataset
# spec.
COLUMNS = [
    "WatchID", "JavaEnable", "Title", "GoodEvent", "EventTime", "EventDate",
    "CounterID", "ClientIP", "RegionID", "UserID", "CounterClass", "OS",
    "UserAgent", "URL", "Referer", "IsRefresh", "RefererCategoryID",
    "RefererRegionID", "URLCategoryID", "URLRegionID", "ResolutionWidth",
    "ResolutionHeight", "ResolutionDepth", "FlashMajor", "FlashMinor",
    "FlashMinor2", "NetMajor", "NetMinor", "UserAgentMajor", "UserAgentMinor",
    "CookieEnable", "JavascriptEnable", "IsMobile", "MobilePhone",
    "MobilePhoneModel", "Params", "IPNetworkID", "TraficSourceID",
    "SearchEngineID", "SearchPhrase", "AdvEngineID", "IsArtifical",
    "WindowClientWidth", "WindowClientHeight", "ClientTimeZone",
    "ClientEventTime", "SilverlightVersion1", "SilverlightVersion2",
    "SilverlightVersion3", "SilverlightVersion4", "PageCharset", "CodeVersion",
    "IsLink", "IsDownload", "IsNotBounce", "FUniqID", "OriginalURL", "HID",
    "IsOldCounter", "IsEvent", "IsParameter", "DontCountHits", "WithHash",
    "HitColor", "LocalEventTime", "Age", "Sex", "Income", "Interests",
    "Robotness", "RemoteIP", "WindowName", "OpenerName", "HistoryLength",
    "BrowserLanguage", "BrowserCountry", "SocialNetwork", "SocialAction",
    "HTTPError", "SendTiming", "DNSTiming", "ConnectTiming",
    "ResponseStartTiming", "ResponseEndTiming", "FetchTiming",
    "SocialSourceNetworkID", "SocialSourcePage", "ParamPrice", "ParamOrderID",
    "ParamCurrency", "ParamCurrencyID", "OpenstatServiceName",
    "OpenstatCampaignID", "OpenstatAdID", "OpenstatSourceID", "UTMSource",
    "UTMMedium", "UTMCampaign", "UTMContent", "UTMTerm", "FromTag", "HasGCLID",
    "RefererHash", "URLHash", "CLID",
]

# Columns whose TSV value is a Unix epoch seconds integer and need to be
# emitted as ISO datetime strings for EventQL's DATETIME type. EventDate
# is already YYYY-MM-DD in the TSV; pass it through unchanged.
EPOCH_COLS = {"EventTime", "ClientEventTime", "LocalEventTime"}
EPOCH_IDX = {COLUMNS.index(c) for c in EPOCH_COLS}


def fmt_epoch(s: str) -> str:
    """epoch-seconds -> 'YYYY-MM-DD HH:MM:SS' (UTC)."""
    if not s:
        return ""
    try:
        t = int(s)
    except ValueError:
        return s
    return datetime.fromtimestamp(t, tz=timezone.utc).strftime(
        "%Y-%m-%d %H:%M:%S"
    )


def make_batch(lines: list[bytes]) -> bytes:
    rows = []
    for line in lines:
        # TSV decoding: hits.tsv is latin-1-safe; data.replace('\t', ...)
        # would be wrong for embedded backslash-escaped tabs, but the
        # ClickBench-filtered dataset doesn't contain literal tabs in
        # any cell.
        fields = line.rstrip(b"\n").split(b"\t")
        if len(fields) != len(COLUMNS):
            continue
        data = {}
        for i, name in enumerate(COLUMNS):
            v = fields[i].decode("utf-8", errors="replace")
            if i in EPOCH_IDX:
                v = fmt_epoch(v)
            data[name] = v
        rows.append({"database": DB, "table": TABLE, "data": data})
    return json.dumps(rows, ensure_ascii=False).encode("utf-8")


async def worker(name: int, queue: asyncio.Queue, session: aiohttp.ClientSession,
                 stats: dict):
    while True:
        batch = await queue.get()
        if batch is None:
            queue.task_done()
            break

        body = make_batch(batch)
        last_err = None
        for attempt in range(RETRIES):
            try:
                async with session.post(
                    URL, data=body,
                    headers={"Content-Type": "application/json"},
                ) as resp:
                    if resp.status in (200, 201):
                        stats["ok"] += len(batch)
                        last_err = None
                        break
                    last_err = f"HTTP {resp.status}: {await resp.text()}"
            except Exception as e:
                last_err = repr(e)
            await asyncio.sleep(0.5 * (attempt + 1))
        if last_err is not None:
            stats["err"] += len(batch)
            sys.stderr.write(f"worker {name}: {last_err}\n")
        queue.task_done()


async def main():
    queue: asyncio.Queue = asyncio.Queue(maxsize=WORKERS * 4)
    stats = {"ok": 0, "err": 0}
    timeout = aiohttp.ClientTimeout(total=600)
    conn = aiohttp.TCPConnector(limit=WORKERS * 2)

    async with aiohttp.ClientSession(timeout=timeout, connector=conn) as session:
        workers = [
            asyncio.create_task(worker(i, queue, session, stats))
            for i in range(WORKERS)
        ]

        start = time.time()
        next_report = start + 30
        batch: list[bytes] = []
        # stdin is opened in binary mode so we don't pay UTF-8 decoding
        # at read time — each worker decodes its own batch.
        for line in sys.stdin.buffer:
            batch.append(line)
            if len(batch) >= SHARD:
                await queue.put(batch)
                batch = []

                now = time.time()
                if now >= next_report:
                    elapsed = now - start
                    rate = stats["ok"] / max(elapsed, 1e-3)
                    sys.stderr.write(
                        f"[loader] {stats['ok']} ok, {stats['err']} err, "
                        f"{rate:.0f} rows/s, {elapsed:.0f}s\n"
                    )
                    next_report = now + 30
        if batch:
            await queue.put(batch)

        for _ in range(WORKERS):
            await queue.put(None)
        await asyncio.gather(*workers)

    elapsed = time.time() - start
    rate = stats["ok"] / max(elapsed, 1e-3)
    sys.stderr.write(
        f"[loader] done: {stats['ok']} ok, {stats['err']} err in "
        f"{elapsed:.1f}s ({rate:.0f} rows/s)\n"
    )
    if stats["err"] > 0 and stats["ok"] == 0:
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
