#!/usr/bin/env python3
"""FastAPI wrapper around chDB so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, fixes
                        column types, holds the DataFrame in memory, and
                        returns {"elapsed": <seconds>}
    POST /query      -> body: SQL text. Looks it up in QUERIES, runs it via
                        chdb against the loaded DataFrame, returns
                        {"elapsed": <seconds>}.
    GET  /data-size  -> bytes the DataFrame currently occupies (memory_usage)

The query strings (43 of them, addressing Python(hits)) match the previous
chdb-dataframe/queries.sql, exposed over HTTP.
"""

import os
import timeit

import chdb
import pandas as pd
import uvicorn
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits: pd.DataFrame | None = None  # noqa: F841 — referenced by chdb's Python() table function
conn = None


def _make_runner(sql: str):
    return lambda _df: conn.query(sql, "Null")


# 43 ClickBench queries — chdb addresses the in-process pandas DataFrame named
# `hits` via the Python() table function. SQL strings come straight from the
# prior chdb-dataframe/queries.sql.
_SQL_LIST: list[str] = [
    "SELECT COUNT(*) FROM Python(hits);",
    "SELECT COUNT(*) FROM Python(hits) WHERE AdvEngineID <> 0;",
    "SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM Python(hits);",
    "SELECT AVG(UserID) FROM Python(hits);",
    "SELECT COUNT(DISTINCT UserID) FROM Python(hits);",
    "SELECT COUNT(DISTINCT SearchPhrase) FROM Python(hits);",
    "SELECT MIN(EventDate), MAX(EventDate) FROM Python(hits);",
    "SELECT AdvEngineID, COUNT(*) FROM Python(hits) WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;",
    "SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM Python(hits) GROUP BY RegionID ORDER BY u DESC LIMIT 10;",
    "SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM Python(hits) GROUP BY RegionID ORDER BY c DESC LIMIT 10;",
    "SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM Python(hits) WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;",
    "SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM Python(hits) WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;",
    "SELECT SearchPhrase, COUNT(*) AS c FROM Python(hits) WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM Python(hits) WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;",
    "SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM Python(hits) WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT UserID, COUNT(*) FROM Python(hits) GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID, SearchPhrase, COUNT(*) FROM Python(hits) GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID, SearchPhrase, COUNT(*) FROM Python(hits) GROUP BY UserID, SearchPhrase LIMIT 10;",
    "SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM Python(hits) GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
    "SELECT UserID FROM Python(hits) WHERE UserID = 435090932899640449;",
    "SELECT COUNT(*) FROM Python(hits) WHERE URL LIKE '%google%';",
    "SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM Python(hits) WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM Python(hits) WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
    "SELECT * FROM Python(hits) WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;",
    "SELECT SearchPhrase FROM Python(hits) WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;",
    "SELECT SearchPhrase FROM Python(hits) WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;",
    "SELECT SearchPhrase FROM Python(hits) WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;",
    "SELECT CounterID, AVG(length(URL)) AS l, COUNT(*) AS c FROM Python(hits) WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
    "SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\\.)?([^/]+)/.*$', '\\1') AS k, AVG(length(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM Python(hits) WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
    "SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9), SUM(ResolutionWidth + 10), SUM(ResolutionWidth + 11), SUM(ResolutionWidth + 12), SUM(ResolutionWidth + 13), SUM(ResolutionWidth + 14), SUM(ResolutionWidth + 15), SUM(ResolutionWidth + 16), SUM(ResolutionWidth + 17), SUM(ResolutionWidth + 18), SUM(ResolutionWidth + 19), SUM(ResolutionWidth + 20), SUM(ResolutionWidth + 21), SUM(ResolutionWidth + 22), SUM(ResolutionWidth + 23), SUM(ResolutionWidth + 24), SUM(ResolutionWidth + 25), SUM(ResolutionWidth + 26), SUM(ResolutionWidth + 27), SUM(ResolutionWidth + 28), SUM(ResolutionWidth + 29), SUM(ResolutionWidth + 30), SUM(ResolutionWidth + 31), SUM(ResolutionWidth + 32), SUM(ResolutionWidth + 33), SUM(ResolutionWidth + 34), SUM(ResolutionWidth + 35), SUM(ResolutionWidth + 36), SUM(ResolutionWidth + 37), SUM(ResolutionWidth + 38), SUM(ResolutionWidth + 39), SUM(ResolutionWidth + 40), SUM(ResolutionWidth + 41), SUM(ResolutionWidth + 42), SUM(ResolutionWidth + 43), SUM(ResolutionWidth + 44), SUM(ResolutionWidth + 45), SUM(ResolutionWidth + 46), SUM(ResolutionWidth + 47), SUM(ResolutionWidth + 48), SUM(ResolutionWidth + 49), SUM(ResolutionWidth + 50), SUM(ResolutionWidth + 51), SUM(ResolutionWidth + 52), SUM(ResolutionWidth + 53), SUM(ResolutionWidth + 54), SUM(ResolutionWidth + 55), SUM(ResolutionWidth + 56), SUM(ResolutionWidth + 57), SUM(ResolutionWidth + 58), SUM(ResolutionWidth + 59), SUM(ResolutionWidth + 60), SUM(ResolutionWidth + 61), SUM(ResolutionWidth + 62), SUM(ResolutionWidth + 63), SUM(ResolutionWidth + 64), SUM(ResolutionWidth + 65), SUM(ResolutionWidth + 66), SUM(ResolutionWidth + 67), SUM(ResolutionWidth + 68), SUM(ResolutionWidth + 69), SUM(ResolutionWidth + 70), SUM(ResolutionWidth + 71), SUM(ResolutionWidth + 72), SUM(ResolutionWidth + 73), SUM(ResolutionWidth + 74), SUM(ResolutionWidth + 75), SUM(ResolutionWidth + 76), SUM(ResolutionWidth + 77), SUM(ResolutionWidth + 78), SUM(ResolutionWidth + 79), SUM(ResolutionWidth + 80), SUM(ResolutionWidth + 81), SUM(ResolutionWidth + 82), SUM(ResolutionWidth + 83), SUM(ResolutionWidth + 84), SUM(ResolutionWidth + 85), SUM(ResolutionWidth + 86), SUM(ResolutionWidth + 87), SUM(ResolutionWidth + 88), SUM(ResolutionWidth + 89) FROM Python(hits);",
    "SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM Python(hits) WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM Python(hits) WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM Python(hits) GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS c FROM Python(hits) GROUP BY URL ORDER BY c DESC LIMIT 10;",
    "SELECT 1, URL, COUNT(*) AS c FROM Python(hits) GROUP BY 1, URL ORDER BY c DESC LIMIT 10;",
    "SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM Python(hits) GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10;",
    "SELECT Title, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10;",
    "SELECT URL, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
    "SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
    "SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100;",
    "SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;",
    "SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM Python(hits) WHERE CounterID = 62  AND EventDate >= '2013-07-14'  AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000",
]

QUERIES: list[tuple[str, callable]] = [(sql, _make_runner(sql)) for sql in _SQL_LIST]
QUERY_INDEX = {sql: i for i, (sql, _) in enumerate(QUERIES)}


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits, conn
    start = timeit.default_timer()
    df = pd.read_parquet("hits.parquet")
    df["EventTime"] = pd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = pd.to_datetime(df["EventDate"], unit="D")
    for col in df.columns:
        if df[col].dtype == "O":
            df[col] = df[col].astype(str)
    hits = df
    # chdb addresses `hits` via Python(hits); the connection picks up the
    # variable from the module globals at query time.
    conn = chdb.connect("./tmp")
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
    sql = QUERIES[idx][0]
    start = timeit.default_timer()
    conn.query(sql, "Null")
    elapsed = round(timeit.default_timer() - start, 3)
    return {"elapsed": elapsed, "index": idx}


@app.get("/data-size")
def data_size():
    if hits is None:
        return {"bytes": 0}
    return {"bytes": int(hits.memory_usage().sum())}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_CHDB_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
