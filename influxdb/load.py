#!/usr/bin/env python3
"""Stream hits.tsv into InfluxDB 3 via line protocol over HTTP.

Each row of the TSV becomes one line-protocol point in measurement ``hits``.
All columns are written as fields (no tags). The line protocol timestamp is
derived from the row index so that every point is unique.

Batches are encoded and uploaded by a thread pool: encoding happens under
the GIL, but the HTTP upload releases the GIL while waiting on the socket
and on the InfluxDB server, so several uploads can be in flight at once.
"""

import csv
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

URL = "http://localhost:8181/api/v3/write_lp"
DB = "hits"
INPUT = "hits.tsv"
TOTAL_ROWS = 99997497

# Each line-protocol point is roughly 2 KB encoded (105 fields with their
# names repeated on every row). 2000 rows keeps the body comfortably under
# the 64 MiB max-http-request-size we set on the server. Larger batches mean
# fewer HTTP round-trips.
BATCH_ROWS = 2000

# Number of upload workers. InfluxDB's per-connection ingest is limited; what
# scales here is concurrent in-flight HTTP requests. 16 workers gives ~30×
# the throughput of single-threaded loading on this dataset; doubling to 32
# only adds another ~10%.
WORKERS = 16

# Bound the in-flight queue so we don't accumulate gigabytes of pending
# bodies if the server back-pressures.
MAX_PENDING = WORKERS * 2

PROGRESS_INTERVAL_SECONDS = 30

# 2020-01-01 00:00:00 UTC, in nanoseconds. Row i is written at TS_BASE + i ns,
# guaranteeing per-row uniqueness while keeping timestamps in a reasonable range.
TS_BASE = 1577836800_000_000_000

# Column schema (name, type) in TSV order. Type 'i' = integer, 's' = string.
# Mirrors postgresql/create.sql.
COLUMNS = [
    ("WatchID", "i"),
    ("JavaEnable", "i"),
    ("Title", "s"),
    ("GoodEvent", "i"),
    ("EventTime", "s"),
    ("EventDate", "s"),
    ("CounterID", "i"),
    ("ClientIP", "i"),
    ("RegionID", "i"),
    ("UserID", "i"),
    ("CounterClass", "i"),
    ("OS", "i"),
    ("UserAgent", "i"),
    ("URL", "s"),
    ("Referer", "s"),
    ("IsRefresh", "i"),
    ("RefererCategoryID", "i"),
    ("RefererRegionID", "i"),
    ("URLCategoryID", "i"),
    ("URLRegionID", "i"),
    ("ResolutionWidth", "i"),
    ("ResolutionHeight", "i"),
    ("ResolutionDepth", "i"),
    ("FlashMajor", "i"),
    ("FlashMinor", "i"),
    ("FlashMinor2", "s"),
    ("NetMajor", "i"),
    ("NetMinor", "i"),
    ("UserAgentMajor", "i"),
    ("UserAgentMinor", "s"),
    ("CookieEnable", "i"),
    ("JavascriptEnable", "i"),
    ("IsMobile", "i"),
    ("MobilePhone", "i"),
    ("MobilePhoneModel", "s"),
    ("Params", "s"),
    ("IPNetworkID", "i"),
    ("TraficSourceID", "i"),
    ("SearchEngineID", "i"),
    ("SearchPhrase", "s"),
    ("AdvEngineID", "i"),
    ("IsArtifical", "i"),
    ("WindowClientWidth", "i"),
    ("WindowClientHeight", "i"),
    ("ClientTimeZone", "i"),
    ("ClientEventTime", "s"),
    ("SilverlightVersion1", "i"),
    ("SilverlightVersion2", "i"),
    ("SilverlightVersion3", "i"),
    ("SilverlightVersion4", "i"),
    ("PageCharset", "s"),
    ("CodeVersion", "i"),
    ("IsLink", "i"),
    ("IsDownload", "i"),
    ("IsNotBounce", "i"),
    ("FUniqID", "i"),
    ("OriginalURL", "s"),
    ("HID", "i"),
    ("IsOldCounter", "i"),
    ("IsEvent", "i"),
    ("IsParameter", "i"),
    ("DontCountHits", "i"),
    ("WithHash", "i"),
    ("HitColor", "s"),
    ("LocalEventTime", "s"),
    ("Age", "i"),
    ("Sex", "i"),
    ("Income", "i"),
    ("Interests", "i"),
    ("Robotness", "i"),
    ("RemoteIP", "i"),
    ("WindowName", "i"),
    ("OpenerName", "i"),
    ("HistoryLength", "i"),
    ("BrowserLanguage", "s"),
    ("BrowserCountry", "s"),
    ("SocialNetwork", "s"),
    ("SocialAction", "s"),
    ("HTTPError", "i"),
    ("SendTiming", "i"),
    ("DNSTiming", "i"),
    ("ConnectTiming", "i"),
    ("ResponseStartTiming", "i"),
    ("ResponseEndTiming", "i"),
    ("FetchTiming", "i"),
    ("SocialSourceNetworkID", "i"),
    ("SocialSourcePage", "s"),
    ("ParamPrice", "i"),
    ("ParamOrderID", "s"),
    ("ParamCurrency", "s"),
    ("ParamCurrencyID", "i"),
    ("OpenstatServiceName", "s"),
    ("OpenstatCampaignID", "s"),
    ("OpenstatAdID", "s"),
    ("OpenstatSourceID", "s"),
    ("UTMSource", "s"),
    ("UTMMedium", "s"),
    ("UTMCampaign", "s"),
    ("UTMContent", "s"),
    ("UTMTerm", "s"),
    ("FromTag", "s"),
    ("HasGCLID", "i"),
    ("RefererHash", "i"),
    ("URLHash", "i"),
    ("CLID", "i"),
]

# String fields need each value individually escaped; integers can be written raw.
_STR_TRANS = str.maketrans({"\\": "\\\\", '"': '\\"', "\n": " ", "\r": " "})

# DataFusion (the InfluxDB 3 query engine) folds unquoted identifiers to
# lowercase, so we lowercase field names at load time. That way the standard
# ClickBench queries with CamelCase column references (e.g. ``EventDate``)
# resolve correctly without needing to be quoted.
_LOWER_COLUMNS = [(name.lower(), ty) for name, ty in COLUMNS]
_NUM_COLS = len(_LOWER_COLUMNS)

_session = requests.Session()
_session.headers["Content-Type"] = "text/plain; charset=utf-8"
_PARAMS = {"db": DB, "precision": "nanosecond", "accept_partial": "false"}


def encode_and_upload(rows, ts_start):
    out = []
    for i, row in enumerate(rows):
        if len(row) != _NUM_COLS:
            row = (row + [""] * _NUM_COLS)[:_NUM_COLS]
        parts = []
        for (name, ty), value in zip(_LOWER_COLUMNS, row):
            if ty == "i":
                # Integer field — append 'i' suffix per line-protocol spec.
                # Empty/blank cells become 0.
                v = value if value else "0"
                parts.append(f"{name}={v}i")
            else:
                v = value.translate(_STR_TRANS) if value else ""
                parts.append(f'{name}="{v}"')
        out.append(f"hits {','.join(parts)} {ts_start + i}\n")

    body = "".join(out).encode("utf-8")
    r = _session.post(URL, params=_PARAMS, data=body, timeout=600)
    if r.status_code >= 300:
        sys.stderr.write(f"write_lp HTTP {r.status_code}: {r.text[:500]}\n")


def main():
    total = 0
    next_ts = TS_BASE
    last_log = time.monotonic()
    pending = []

    with ThreadPoolExecutor(max_workers=WORKERS) as executor:
        with open(INPUT, "r", encoding="utf-8", errors="replace", newline="") as f:
            reader = csv.reader(
                f, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar=None
            )
            batch = []
            for row in reader:
                batch.append(row)
                if len(batch) < BATCH_ROWS:
                    continue

                pending.append(executor.submit(encode_and_upload, batch, next_ts))
                next_ts += len(batch)
                total += len(batch)
                batch = []

                # Drain oldest futures so memory stays bounded and any error
                # surfaces promptly.
                while len(pending) >= MAX_PENDING:
                    pending.pop(0).result()

                now = time.monotonic()
                if now - last_log > PROGRESS_INTERVAL_SECONDS:
                    pct = 100.0 * total / TOTAL_ROWS
                    print(f"  {pct:5.2f}%  ({total}/{TOTAL_ROWS})", flush=True)
                    last_log = now

            if batch:
                pending.append(executor.submit(encode_and_upload, batch, next_ts))
                total += len(batch)

        for fut in pending:
            fut.result()

    print(f"Total rows written: {total}")


if __name__ == "__main__":
    main()
