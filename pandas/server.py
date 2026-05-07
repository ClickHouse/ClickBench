#!/usr/bin/env python3
"""FastAPI wrapper around pandas so it conforms to the ClickBench
install/start/check/stop/load/query interface.

Routes:
    GET  /health     -> 200 OK once the server is up
    POST /load       -> reads hits.parquet from the working directory, fixes
                        column types, holds the DataFrame in memory, and
                        returns {"elapsed": <seconds>}
    POST /query      -> body: SQL text. Looks it up in QUERIES, runs the
                        matching lambda against the loaded DataFrame, and
                        returns {"elapsed": <seconds>}.
    GET  /data-size  -> bytes the DataFrame currently occupies (memory_usage)

The (sql, lambda) list is the same as the previous standalone query.py — just
exposed over HTTP. queries.sql in this directory holds the SQL strings in the
same order.
"""

import os
import timeit

import pandas as pd
import uvicorn
from fastapi import FastAPI, HTTPException, Request

app = FastAPI()
hits: pd.DataFrame | None = None


# 43 ClickBench queries. Each is (sql, callable). sql strings must match the
# corresponding line in queries.sql. The lambdas come straight from the prior
# pandas/query.py and have not been modified.
QUERIES: list[tuple[str, callable]] = [
    ("SELECT COUNT(*) FROM hits;", lambda x: x.count()),
    (
        "SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;",
        lambda x: x[x["AdvEngineID"] != 0].count(),
    ),
    (
        "SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;",
        lambda x: (x["AdvEngineID"].sum(), x.shape[0], x["ResolutionWidth"].mean()),
    ),
    ("SELECT AVG(UserID) FROM hits;", lambda x: x["UserID"].mean()),
    ("SELECT COUNT(DISTINCT UserID) FROM hits;", lambda x: x["UserID"].nunique()),
    (
        "SELECT COUNT(DISTINCT SearchPhrase) FROM hits;",
        lambda x: x["SearchPhrase"].nunique(),
    ),
    (
        "SELECT MIN(EventDate), MAX(EventDate) FROM hits;",
        lambda x: (x["EventDate"].min(), x["EventDate"].max()),
    ),
    (
        "SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;",
        lambda x: x[x["AdvEngineID"] != 0]
        .groupby("AdvEngineID")
        .size()
        .sort_values(ascending=False),
    ),
    (
        "SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;",
        lambda x: x.groupby("RegionID")["UserID"].nunique().nlargest(10),
    ),
    (
        "SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby("RegionID")
        .agg({"AdvEngineID": "sum", "ResolutionWidth": "mean", "UserID": "nunique"})
        .nlargest(10, "AdvEngineID"),
    ),
    (
        "SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["MobilePhoneModel"] != ""]
        .groupby("MobilePhoneModel")["UserID"]
        .nunique()
        .nlargest(10),
    ),
    (
        "SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["MobilePhoneModel"] != ""]
        .groupby(["MobilePhone", "MobilePhoneModel"])["UserID"]
        .nunique()
        .nlargest(10),
    ),
    (
        "SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby("SearchPhrase")
        .size()
        .nlargest(10),
    ),
    (
        "SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby("SearchPhrase")["UserID"]
        .nunique()
        .nlargest(10),
    ),
    (
        "SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["SearchEngineID", "SearchPhrase"])
        .size()
        .nlargest(10),
    ),
    (
        "SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby("UserID").size().nlargest(10),
    ),
    (
        "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby(["UserID", "SearchPhrase"]).size().nlargest(10),
    ),
    (
        "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;",
        lambda x: x.groupby(["UserID", "SearchPhrase"]).size().head(10),
    ),
    (
        "SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby([x["UserID"], x["EventTime"].dt.minute, "SearchPhrase"])
        .size()
        .nlargest(10),
    ),
    (
        "SELECT UserID FROM hits WHERE UserID = 435090932899640449;",
        lambda x: x[x["UserID"] == 435090932899640449],
    ),
    (
        "SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';",
        lambda x: x[x["URL"].str.contains("google")].shape[0],
    ),
    (
        "SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[(x["URL"].str.contains("google")) & (x["SearchPhrase"] != "")]
        .groupby("SearchPhrase")
        .agg({"URL": "min", "SearchPhrase": "size"})
        .nlargest(10, "SearchPhrase"),
    ),
    (
        "SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[
            (x["Title"].str.contains("Google"))
            & (~x["URL"].str.contains(".google."))
            & (x["SearchPhrase"] != "")
        ]
        .groupby("SearchPhrase")
        .agg(
            {"URL": "min", "Title": "min", "SearchPhrase": "size", "UserID": "nunique"}
        )
        .nlargest(10, "SearchPhrase"),
    ),
    (
        "SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;",
        lambda x: x[x["URL"].str.contains("google")]
        .sort_values(by="EventTime")
        .head(10),
    ),
    (
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by="EventTime")[["SearchPhrase"]]
        .head(10),
    ),
    (
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by="SearchPhrase")[["SearchPhrase"]]
        .head(10),
    ),
    (
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by=["EventTime", "SearchPhrase"])[["SearchPhrase"]]
        .head(10),
    ),
    (
        "SELECT CounterID, AVG(STRLEN(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
        lambda x: x[x["URL"] != ""]
        .groupby("CounterID")
        .filter(lambda g: g["URL"].count() > 100000)
        .agg({"URL": lambda url: url.str.len().mean(), "CounterID": "size"})
        .sort_values()
        .head(25),
    ),
    (
        "SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\\.)?([^/]+)/.*$', '\\1') AS k, AVG(STRLEN(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
        lambda x: (
            x[x["Referer"] != ""]
            .assign(k=x["Referer"].str.extract(r"^https?://(?:www\.)?([^/]+)/.*$")[0])
            .groupby("k")
            .filter(lambda g: g["Referer"].count() > 100000)
            .agg(
                min_referer=("Referer", "min"),
                average_length=("Referer", lambda r: r.str.len().mean()),
            )
            .head(25)
        ),
    ),
    (
        "SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9), SUM(ResolutionWidth + 10), SUM(ResolutionWidth + 11), SUM(ResolutionWidth + 12), SUM(ResolutionWidth + 13), SUM(ResolutionWidth + 14), SUM(ResolutionWidth + 15), SUM(ResolutionWidth + 16), SUM(ResolutionWidth + 17), SUM(ResolutionWidth + 18), SUM(ResolutionWidth + 19), SUM(ResolutionWidth + 20), SUM(ResolutionWidth + 21), SUM(ResolutionWidth + 22), SUM(ResolutionWidth + 23), SUM(ResolutionWidth + 24), SUM(ResolutionWidth + 25), SUM(ResolutionWidth + 26), SUM(ResolutionWidth + 27), SUM(ResolutionWidth + 28), SUM(ResolutionWidth + 29), SUM(ResolutionWidth + 30), SUM(ResolutionWidth + 31), SUM(ResolutionWidth + 32), SUM(ResolutionWidth + 33), SUM(ResolutionWidth + 34), SUM(ResolutionWidth + 35), SUM(ResolutionWidth + 36), SUM(ResolutionWidth + 37), SUM(ResolutionWidth + 38), SUM(ResolutionWidth + 39), SUM(ResolutionWidth + 40), SUM(ResolutionWidth + 41), SUM(ResolutionWidth + 42), SUM(ResolutionWidth + 43), SUM(ResolutionWidth + 44), SUM(ResolutionWidth + 45), SUM(ResolutionWidth + 46), SUM(ResolutionWidth + 47), SUM(ResolutionWidth + 48), SUM(ResolutionWidth + 49), SUM(ResolutionWidth + 50), SUM(ResolutionWidth + 51), SUM(ResolutionWidth + 52), SUM(ResolutionWidth + 53), SUM(ResolutionWidth + 54), SUM(ResolutionWidth + 55), SUM(ResolutionWidth + 56), SUM(ResolutionWidth + 57), SUM(ResolutionWidth + 58), SUM(ResolutionWidth + 59), SUM(ResolutionWidth + 60), SUM(ResolutionWidth + 61), SUM(ResolutionWidth + 62), SUM(ResolutionWidth + 63), SUM(ResolutionWidth + 64), SUM(ResolutionWidth + 65), SUM(ResolutionWidth + 66), SUM(ResolutionWidth + 67), SUM(ResolutionWidth + 68), SUM(ResolutionWidth + 69), SUM(ResolutionWidth + 70), SUM(ResolutionWidth + 71), SUM(ResolutionWidth + 72), SUM(ResolutionWidth + 73), SUM(ResolutionWidth + 74), SUM(ResolutionWidth + 75), SUM(ResolutionWidth + 76), SUM(ResolutionWidth + 77), SUM(ResolutionWidth + 78), SUM(ResolutionWidth + 79), SUM(ResolutionWidth + 80), SUM(ResolutionWidth + 81), SUM(ResolutionWidth + 82), SUM(ResolutionWidth + 83), SUM(ResolutionWidth + 84), SUM(ResolutionWidth + 85), SUM(ResolutionWidth + 86), SUM(ResolutionWidth + 87), SUM(ResolutionWidth + 88), SUM(ResolutionWidth + 89) FROM hits;",
        lambda x: sum(x["ResolutionWidth"].shift(i).sum() for i in range(90)),
    ),
    (
        "SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["SearchEngineID", "ClientIP"])
        .agg(
            c=("SearchEngineID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
    ),
    (
        "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["WatchID", "ClientIP"])
        .agg(
            c=("WatchID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
    ),
    (
        "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby(["WatchID", "ClientIP"])
        .agg(
            c=("WatchID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
    ),
    (
        "SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby("URL").size().nlargest(10).reset_index(name="c"),
    ),
    (
        "SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby(["URL"]).size().nlargest(10).reset_index(name="c"),
    ),
    (
        "SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10;",
        lambda x: x.assign(
            **{f"ClientIP_minus_{i}": x["ClientIP"] - i for i in range(1, 4)}
        )
        .groupby(
            ["ClientIP", "ClientIP_minus_1", "ClientIP_minus_2", "ClientIP_minus_3"]
        )
        .size()
        .nlargest(10)
        .reset_index(name="c"),
    ),
    (
        "SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["DontCountHits"] == 0)
            & (x["IsRefresh"] == 0)
            & (x["URL"] != "")
        ]
        .groupby("URL")
        .size()
        .nlargest(10),
    ),
    (
        "SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["DontCountHits"] == 0)
            & (x["IsRefresh"] == 0)
            & (x["Title"] != "")
        ]
        .groupby("Title")
        .size()
        .nlargest(10),
    ),
    (
        "SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["IsRefresh"] == 0)
            & (x["IsLink"] != 0)
            & (x["IsDownload"] == 0)
        ]
        .groupby("URL")
        .size()
        .nlargest(10)
        .reset_index(name="PageViews")
        .iloc[1000:1010],
    ),
    (
        "SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["IsRefresh"] == 0)
        ]
        .groupby(["TraficSourceID", "SearchEngineID", "AdvEngineID", "Referer", "URL"])
        .size()
        .nlargest(10)
        .reset_index(name="PageViews")
        .iloc[1000:1010],
    ),
    (
        "SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["IsRefresh"] == 0)
            & (x["TraficSourceID"].isin([-1, 6]))
            & (x["RefererHash"] == 3594120000172545465)
        ]
        .groupby(["URLHash", "EventDate"])
        .size()
        .nlargest(10)
        .reset_index(name="PageViews")
        .iloc[100:110],
    ),
    (
        "SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-01")
            & (x["EventDate"] <= "2013-07-31")
            & (x["IsRefresh"] == 0)
            & (x["DontCountHits"] == 0)
            & (x["URLHash"] == 2868770270353813622)
        ]
        .groupby(["WindowClientWidth", "WindowClientHeight"])
        .size()
        .nlargest(10)
        .reset_index(name="PageViews")
        .iloc[10000:10010],
    ),
    (
        "SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000;",
        lambda x: x[
            (x["CounterID"] == 62)
            & (x["EventDate"] >= "2013-07-14")
            & (x["EventDate"] <= "2013-07-15")
            & (x["IsRefresh"] == 0)
            & (x["DontCountHits"] == 0)
        ]
        .groupby(pd.Grouper(key="EventTime", freq="T"))
        .size()
        .reset_index(name="PageViews")
        .iloc[1000:1010],
    ),
]

QUERY_INDEX = {sql: i for i, (sql, _) in enumerate(QUERIES)}


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/load")
def load():
    global hits
    start = timeit.default_timer()
    df = pd.read_parquet("hits.parquet")
    df["EventTime"] = pd.to_datetime(df["EventTime"], unit="s")
    df["EventDate"] = pd.to_datetime(df["EventDate"], unit="D")
    for col in df.columns:
        if df[col].dtype == "O":
            df[col] = df[col].astype(str)
    hits = df
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
    if hits is None:
        return {"bytes": 0}
    return {"bytes": int(hits.memory_usage().sum())}


if __name__ == "__main__":
    port = int(os.environ.get("BENCH_PANDAS_PORT", "8000"))
    uvicorn.run(app, host="127.0.0.1", port=port, log_level="warning")
