#!/usr/bin/env python3
"""Stream hits.tsv into InfluxDB 3 via line protocol over HTTP.

Each row of the TSV becomes one line-protocol point in measurement ``hits``.
All columns are written as fields (no tags). The line protocol timestamp is
derived from the row index so that every point is unique.
"""

import csv
import os
import sys
import time
import requests

URL = "http://localhost:8181/api/v3/write_lp"
DB = "hits"
INPUT = "hits.tsv"
TOTAL_ROWS = 99997497
BATCH_ROWS = 1000

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

# Pre-compute static parts of each line for speed.
# String fields need each value individually escaped; integers can be written raw.
_STR_TRANS = str.maketrans({"\\": "\\\\", '"': '\\"', "\n": " ", "\r": " "})


# DataFusion (the InfluxDB 3 query engine) folds unquoted identifiers to
# lowercase, so we lowercase field names at load time. That way the standard
# ClickBench queries with CamelCase column references (e.g. ``EventDate``)
# resolve correctly without needing to be quoted.
_LOWER_COLUMNS = [(name.lower(), ty) for name, ty in COLUMNS]


def encode_row(row, ts_ns):
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
    return f"hits {','.join(parts)} {ts_ns}\n"


def main():
    session = requests.Session()
    session.headers["Content-Type"] = "text/plain; charset=utf-8"
    params = {"db": DB, "precision": "nanosecond", "accept_partial": "false"}

    total = 0
    last_log = time.monotonic()
    buf = []

    with open(INPUT, "r", encoding="utf-8", errors="replace", newline="") as f:
        reader = csv.reader(
            f, delimiter="\t", quoting=csv.QUOTE_NONE, escapechar=None
        )
        for i, row in enumerate(reader):
            if len(row) != len(COLUMNS):
                # Pad short rows / truncate over-long ones; the source TSV is
                # mostly clean but defensive handling avoids killing the load.
                row = (row + [""] * len(COLUMNS))[: len(COLUMNS)]
            buf.append(encode_row(row, TS_BASE + i))
            if len(buf) >= BATCH_ROWS:
                _flush(session, params, buf)
                total += len(buf)
                buf.clear()
                now = time.monotonic()
                if now - last_log > 5:
                    pct = 100.0 * total / TOTAL_ROWS
                    print(f"  {pct:5.2f}%  ({total}/{TOTAL_ROWS})", flush=True)
                    last_log = now
    if buf:
        _flush(session, params, buf)
        total += len(buf)

    print(f"Total rows written: {total}")


def _flush(session, params, buf):
    body = "".join(buf).encode("utf-8")
    r = session.post(URL, params=params, data=body, timeout=300)
    if r.status_code >= 300:
        sys.stderr.write(f"write_lp HTTP {r.status_code}: {r.text[:500]}\n")


if __name__ == "__main__":
    main()
