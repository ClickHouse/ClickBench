#!/usr/bin/env python3
"""FastAPI wrapper around Daft (single-file parquet) so it conforms to the
ClickBench install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, casts
                        types, holds the Daft DataFrame in memory, registers
                        it as `hits` for daft.sql, returns {"elapsed": ...}
    POST /query      -> body: SQL text. Looks it up in QUERIES, runs the
                        matching callable via daft.sql, returns
                        {"elapsed": <seconds>}.
    GET  /data-size  -> file size of hits.parquet at load time.

The 43 SQL strings come straight from the prior daft-parquet/queries.sql.
"""

import os
import timeit

import daft
import uvicorn
from daft import DataType, col
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits = None
data_bytes = 0

PARQUET_GLOB = os.environ.get("BENCH_DAFT_PARQUET", "hits.parquet")


def _make_runner(sql: str):
    return lambda _df: daft.sql(sql).collect()


# 43 ClickBench queries — daft.sql against the registered `hits` view.
_SQL_LIST: list[str] = [
    "SELECT COUNT(*) FROM hits;",
    "SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;",
    "SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;",
    "SELECT AVG(UserID) FROM hits;",
    "SELECT COUNT(DISTINCT UserID) FROM hits;",
    "SELECT COUNT(DISTINCT SearchPhrase) FROM hits;",
    "SELECT MIN(EventDate) as m1, MAX(EventDate) as m2 FROM hits;",
    "SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;",
    "SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;",
    "SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;",
    "SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;",
    "SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;",
    "SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;",
    "SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;",
    "SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID FROM hits WHERE UserID = 435090932899640449;",
    "SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';",
    "SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;",
    "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;",
    "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;",
    "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;",
    "SELECT CounterID, AVG(length(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
    "SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\\.)?([^/]+)/.*$', '\\1') AS k, AVG(length(Referer)) AS l, COUNT(*) AS c, MIN(Referer) as m FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
    "SELECT SUM(ResolutionWidth) AS s0, SUM(ResolutionWidth + 1) AS s1, SUM(ResolutionWidth + 2) AS s2, SUM(ResolutionWidth + 3) AS s3, SUM(ResolutionWidth + 4) AS s4, SUM(ResolutionWidth + 5) AS s5, SUM(ResolutionWidth + 6) AS s6, SUM(ResolutionWidth + 7) AS s7, SUM(ResolutionWidth + 8) AS s8, SUM(ResolutionWidth + 9) AS s9, SUM(ResolutionWidth + 10) AS s10, SUM(ResolutionWidth + 11) AS s11, SUM(ResolutionWidth + 12) AS s12, SUM(ResolutionWidth + 13) AS s13, SUM(ResolutionWidth + 14) AS s14, SUM(ResolutionWidth + 15) AS s15, SUM(ResolutionWidth + 16) AS s16, SUM(ResolutionWidth + 17) AS s17, SUM(ResolutionWidth + 18) AS s18, SUM(ResolutionWidth + 19) AS s19, SUM(ResolutionWidth + 20) AS s20, SUM(ResolutionWidth + 21) AS s21, SUM(ResolutionWidth + 22) AS s22, SUM(ResolutionWidth + 23) AS s23, SUM(ResolutionWidth + 24) AS s24, SUM(ResolutionWidth + 25) AS s25, SUM(ResolutionWidth + 26) AS s26, SUM(ResolutionWidth + 27) AS s27, SUM(ResolutionWidth + 28) AS s28, SUM(ResolutionWidth + 29) AS s29, SUM(ResolutionWidth + 30) AS s30, SUM(ResolutionWidth + 31) AS s31, SUM(ResolutionWidth + 32) AS s32, SUM(ResolutionWidth + 33) AS s33, SUM(ResolutionWidth + 34) AS s34, SUM(ResolutionWidth + 35) AS s35, SUM(ResolutionWidth + 36) AS s36, SUM(ResolutionWidth + 37) AS s37, SUM(ResolutionWidth + 38) AS s38, SUM(ResolutionWidth + 39) AS s39, SUM(ResolutionWidth + 40) AS s40, SUM(ResolutionWidth + 41) AS s41, SUM(ResolutionWidth + 42) AS s42, SUM(ResolutionWidth + 43) AS s43, SUM(ResolutionWidth + 44) AS s44, SUM(ResolutionWidth + 45) AS s45, SUM(ResolutionWidth + 46) AS s46, SUM(ResolutionWidth + 47) AS s47, SUM(ResolutionWidth + 48) AS s48, SUM(ResolutionWidth + 49) AS s49, SUM(ResolutionWidth + 50) AS s50, SUM(ResolutionWidth + 51) AS s51, SUM(ResolutionWidth + 52) AS s52, SUM(ResolutionWidth + 53) AS s53, SUM(ResolutionWidth + 54) AS s54, SUM(ResolutionWidth + 55) AS s55, SUM(ResolutionWidth + 56) AS s56, SUM(ResolutionWidth + 57) AS s57, SUM(ResolutionWidth + 58) AS s58, SUM(ResolutionWidth + 59) AS s59, SUM(ResolutionWidth + 60) AS s60, SUM(ResolutionWidth + 61) AS s61, SUM(ResolutionWidth + 62) AS s62, SUM(ResolutionWidth + 63) AS s63, SUM(ResolutionWidth + 64) AS s64, SUM(ResolutionWidth + 65) AS s65, SUM(ResolutionWidth + 66) AS s66, SUM(ResolutionWidth + 67) AS s67, SUM(ResolutionWidth + 68) AS s68, SUM(ResolutionWidth + 69) AS s69, SUM(ResolutionWidth + 70) AS s70, SUM(ResolutionWidth + 71) AS s71, SUM(ResolutionWidth + 72) AS s72, SUM(ResolutionWidth + 73) AS s73, SUM(ResolutionWidth + 74) AS s74, SUM(ResolutionWidth + 75) AS s75, SUM(ResolutionWidth + 76) AS s76, SUM(ResolutionWidth + 77) AS s77, SUM(ResolutionWidth + 78) AS s78, SUM(ResolutionWidth + 79) AS s79, SUM(ResolutionWidth + 80) AS s80, SUM(ResolutionWidth + 81) AS s81, SUM(ResolutionWidth + 82) AS s82, SUM(ResolutionWidth + 83) AS s83, SUM(ResolutionWidth + 84) AS s84, SUM(ResolutionWidth + 85) AS s85, SUM(ResolutionWidth + 86) AS s86, SUM(ResolutionWidth + 87) AS s87, SUM(ResolutionWidth + 88) AS s88, SUM(ResolutionWidth + 89) AS s89 FROM hits;",
    "SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;",
    "SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;",
    "SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10;",
    "SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
    "SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
    "SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100;",
    "SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;",
    "SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000;",
]

QUERIES: list[tuple[str, callable]] = [(sql, _make_runner(sql)) for sql in _SQL_LIST]
QUERY_INDEX = {sql: i for i, (sql, _) in enumerate(QUERIES)}


def _data_size_bytes() -> int:
    import glob
    total = 0
    for p in glob.glob(PARQUET_GLOB):
        try:
            total += os.path.getsize(p)
        except OSError:
            pass
    return total


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits, data_bytes
    start = timeit.default_timer()
    data_bytes = _data_size_bytes()
    df = daft.read_parquet(PARQUET_GLOB)
    df = df.with_column("EventTime", col("EventTime").cast(DataType.timestamp("s")))
    df = df.with_column("EventDate", col("EventDate").cast(DataType.date()))
    df = df.with_column("URL", col("URL").decode("utf-8"))
    df = df.with_column("Title", col("Title").decode("utf-8"))
    df = df.with_column("Referer", col("Referer").decode("utf-8"))
    df = df.with_column("MobilePhoneModel", col("MobilePhoneModel").decode("utf-8"))
    df = df.with_column("SearchPhrase", col("SearchPhrase").decode("utf-8"))
    hits = df
    # Register so daft.sql can see `hits`.
    try:
        daft.catalog.register_table("hits", df)  # type: ignore[attr-defined]
    except Exception:
        pass
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed}


@app.post("/query")
async def query(request: Request):
    if hits is None:
        raise HTTPException(status_code=409, detail="DataFrame not loaded; POST /load first")
    body = (await request.body()).decode("utf-8").strip()
    idx = QUERY_INDEX.get(body)
    if idx is None:
        raise HTTPException(status_code=404, detail=f"unknown query: {body[:120]}")
    fn = QUERIES[idx][1]
    start = timeit.default_timer()
    fn(hits)
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "index": idx}


@app.get("/data-size")
def data_size():
    if data_bytes:
        return {"bytes": int(data_bytes)}
    # Fall back to the on-disk size if /load hasn't run yet.
    return {"bytes": _data_size_bytes()}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_DAFT_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
