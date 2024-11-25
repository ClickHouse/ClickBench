#!/usr/bin/env python3

import pandas as pd
import polars as pl
import timeit
from datetime import datetime, date
import json

hits = pd.read_parquet("hits.parquet")

dataframe_size = hits.memory_usage().sum()

# print("Dataframe(numpy) size:", dataframe_size, "bytes")

# fix some types
hits["EventTime"] = pd.to_datetime(hits["EventTime"], unit="s")
hits["EventDate"] = pd.to_datetime(hits["EventDate"], unit="D")

# fix all object columns to string
for col in hits.columns:
    if hits[col].dtype == "O":
        hits[col] = hits[col].astype(str)

start = timeit.default_timer()
pl_df = pl.DataFrame(hits).rechunk().lazy()
stop = timeit.default_timer()
load_time = stop - start

# 0: No., 1: SQL, 2: Pandas, 3: Polars
queries = [
    ("Q0", "SELECT COUNT(*) FROM hits;", lambda x: x.count(), lambda x: x.select(pl.len()).collect().height),
    (
        "Q1",
        "SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;",
        lambda x: x[x["AdvEngineID"] != 0].count(),
        lambda x: x.select(pl.col("AdvEngineID").filter(pl.col("AdvEngineID") != 0).count()).collect().height,
    ),
    (
        "Q2",
        "SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;",
        lambda x: (x["AdvEngineID"].sum(), x.shape[0], x["ResolutionWidth"].mean()),
        lambda x: x.select(pl.col("advengineid").sum(), pl.len(), pl.col("advengineid").mean()).collect().rows()[0],
    ),
    (
        "Q3",
        "SELECT AVG(UserID) FROM hits;",
        lambda x: x["UserID"].mean(),
        lambda x: x.select(pl.col("UserID").mean()).collect().item(),
    ),
    (
        "Q4",
        "SELECT COUNT(DISTINCT UserID) FROM hits;",
        lambda x: x["UserID"].nunique(),
        lambda x: x.select(pl.col("UserID").n_unique()).collect().item(),
    ),
    (
        "Q5",
        "SELECT COUNT(DISTINCT SearchPhrase) FROM hits;",
        lambda x: x["SearchPhrase"].nunique(),
        lambda x: x.select(pl.col("SearchPhrase").n_unique()).collect().item(),
    ),
    (
        "Q6",
        "SELECT MIN(EventDate), MAX(EventDate) FROM hits;",
        lambda x: (x["EventDate"].min(), x["EventDate"].max()),
        lambda x: x.select(pl.col("EventDate").min().alias("e_min"), pl.col("EventDate").max("e_max")).collect().rows()[0]
    ),
    (
        "Q7",
        "SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;",
        lambda x: x[x["AdvEngineID"] != 0]
        .groupby("AdvEngineID")
        .size()
        .sort_values(ascending=False),
        lambda x: x.filter(pl.col("AdvEngineID") != 0)
        .group_by("AdvEngineID")
        .agg(pl.len().alias("count"))
        .sort("count", descending=True).collect(),
    ),
    (
        "Q8",
        "SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;",
        lambda x: x.groupby("RegionID")["UserID"].nunique().nlargest(10),
        lambda x: x.group_by("RegionID")
        .agg(pl.col("UserID").n_unique())
        .sort("UserID", descending=True)
        .head(10).collect(),
    ),
    (
        "Q9",
        "SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby("RegionID")
        .agg({"AdvEngineID": "sum", "ResolutionWidth": "mean", "UserID": "nunique"})
        .nlargest(10, "AdvEngineID"),
        lambda x: x.group_by("RegionID")
        .agg(
            [
                pl.sum("AdvEngineID").alias("AdvEngineID_sum"),
                pl.mean("ResolutionWidth").alias("ResolutionWidth_mean"),
                pl.col("UserID").n_unique().alias("UserID_nunique"),
            ]
        )
        .sort("AdvEngineID_sum", descending=True)
        .head(10).collect(),
    ),
    (
        "Q10",
        "SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["MobilePhoneModel"] != ""]
        .groupby("MobilePhoneModel")["UserID"]
        .nunique()
        .nlargest(10),
        lambda x: x.filter(pl.col("MobilePhoneModel") != "")
        .group_by("MobilePhoneModel")
        .agg(pl.col("UserID").n_unique())
        .sort("UserID", descending=True)
        .head(10).collect(),
    ),
    (
        "Q11",
        "SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["MobilePhoneModel"] != ""]
        .groupby(["MobilePhone", "MobilePhoneModel"])["UserID"]
        .nunique()
        .nlargest(10),
        lambda x: x.filter(pl.col("MobilePhoneModel") != "")
        .group_by(["MobilePhone", "MobilePhoneModel"])
        .agg(pl.col("UserID").n_unique())
        .sort("UserID", descending=True)
        .head(10).collect(),
    ),
    (
        "Q12",
        "SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby("SearchPhrase")
        .size()
        .nlargest(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .group_by("SearchPhrase")
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q13",
        "SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby("SearchPhrase")["UserID"]
        .nunique()
        .nlargest(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .group_by("SearchPhrase")
        .agg(pl.col("UserID").n_unique())
        .sort("UserID", descending=True)
        .head(10).collect(),
    ),
    (
        "Q14",
        "SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["SearchEngineID", "SearchPhrase"])
        .size()
        .nlargest(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .group_by(["SearchEngineID", "SearchPhrase"])
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q15",
        "SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby("UserID").size().nlargest(10),
        lambda x: x.group_by("UserID")
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q16",
        "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby(["UserID", "SearchPhrase"]).size().nlargest(10),
        lambda x: x.group_by(["UserID", "SearchPhrase"])
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q17",
        "SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;",
        lambda x: x.groupby(["UserID", "SearchPhrase"]).size().head(10),
        lambda x: x.group_by(["UserID", "SearchPhrase"]).agg(pl.len()).head(10).collect(),
    ),
    (
        "Q18",
        "SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;",
        lambda x: x.groupby([x["UserID"], x["EventTime"].dt.minute, "SearchPhrase"])
        .size()
        .nlargest(10),
        lambda x: x.group_by(
            [pl.col("UserID"), x["EventTime"].dt.minute(), "SearchPhrase"]
        )
        .agg(pl.len().alias("count"))
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q19",
        "SELECT UserID FROM hits WHERE UserID = 435090932899640449;",
        lambda x: x[x["UserID"] == 435090932899640449],
        lambda x: x.select("UserID").filter(pl.col("UserID") == 435090932899640449).collect(),
    ),
    (
        "Q20",
        "SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';",
        lambda x: x[x["URL"].str.contains("google")].shape[0],
        lambda x: x.filter(pl.col("URL").str.contains("google")).select(pl.len()).collect().item(),
    ),
    (
        "Q21",
        "SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;",
        lambda x: x[(x["URL"].str.contains("google")) & (x["SearchPhrase"] != "")]
        .groupby("SearchPhrase")
        .agg({"URL": "min", "SearchPhrase": "size"})
        .nlargest(10, "SearchPhrase"),
        lambda x: x.filter(
            (pl.col("URL").str.contains("google")) & (pl.col("SearchPhrase") != "")
        )
        .group_by("SearchPhrase")
        .agg([pl.col("URL").min(), pl.len().alias("count")])
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q22",
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
        lambda x: x.filter(
            (pl.col("Title").str.contains("Google"))
            & (~pl.col("URL").str.contains(".google."))
            & (pl.col("SearchPhrase") != "")
        )
        .group_by("SearchPhrase")
        .agg(
            [
                pl.col("URL").min(),
                pl.col("Title").min(),
                pl.len().alias("count"),
                pl.col("UserID").n_unique(),
            ]
        )
        .sort("count", descending=True)
        .head(10).collect(),
    ),
    (
        "Q23",
        "SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;",
        lambda x: x[x["URL"].str.contains("google")]
        .sort_values(by="EventTime")
        .head(10),
        lambda x: x.filter(pl.col("URL").str.contains("google"))
        .sort("EventTime")
        .head(10).collect(),
    ),
    (
        "Q24",
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by="EventTime")[["SearchPhrase"]]
        .head(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .sort("EventTime")
        .select("SearchPhrase")
        .head(10).collect(),
    ),
    (
        "Q25",
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by="SearchPhrase")[["SearchPhrase"]]
        .head(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .sort("SearchPhrase")
        .select("SearchPhrase")
        .head(10).collect(),
    ),
    (
        "Q26",
        "SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .sort_values(by=["EventTime", "SearchPhrase"])[["SearchPhrase"]]
        .head(10),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .sort(["EventTime", "SearchPhrase"])
        .select("SearchPhrase")
        .head(10).collect(),
    ),
    (
        "Q27",
        "SELECT CounterID, AVG(STRLEN(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;",
        lambda x: x[x["URL"] != ""]
        .groupby("CounterID")
        .filter(lambda g: g["URL"].count() > 100000)
        .agg({"URL": lambda url: url.str.len().mean(), "CounterID": "size"})
        .sort_values()
        .head(25),
        lambda x: x.filter(pl.col("URL") != "")  # WHERE URL <> ''
        .group_by("CounterID")  # GROUP BY CounterID
        .agg(
            [
                pl.col("URL").str.len_chars().mean().alias("l"),  # AVG(STRLEN(URL))
                pl.len().alias("c"),  # COUNT(*)
            ]
        )
        .filter(pl.col("c") > 100000)  # HAVING COUNT(*) > 100000
        .sort("l", descending=True)  # ORDER BY l DESC
        .limit(25).collect(),  # LIMIT 25,
    ),
    (
        "Q28",
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
        lambda x: (
            x.filter(pl.col("Referer") != "")
            .with_columns(
                pl.col("Referer")
                .str.extract(r"^https?://(?:www\\.)?([^/]+)/.*$")
                .alias("k")
            )
            .group_by("k")
            .agg(
                [
                    pl.col("Referer").str.len_chars().mean().alias("l"),  # AVG(STRLEN(Referer))
                    pl.col("Referer").min().alias("min_referer"),  # MIN(Referer)
                    pl.len().alias("c"),  # COUNT(*)
                ]
            )
            .filter(pl.col("c") > 100000)  # HAVING COUNT(*) > 100000
            .sort("l", descending=True)  # ORDER BY l DESC
            .limit(25).collect()  # LIMIT 25
        ),
    ),
    (
        "Q29",
        "SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9), SUM(ResolutionWidth + 10), SUM(ResolutionWidth + 11), SUM(ResolutionWidth + 12), SUM(ResolutionWidth + 13), SUM(ResolutionWidth + 14), SUM(ResolutionWidth + 15), SUM(ResolutionWidth + 16), SUM(ResolutionWidth + 17), SUM(ResolutionWidth + 18), SUM(ResolutionWidth + 19), SUM(ResolutionWidth + 20), SUM(ResolutionWidth + 21), SUM(ResolutionWidth + 22), SUM(ResolutionWidth + 23), SUM(ResolutionWidth + 24), SUM(ResolutionWidth + 25), SUM(ResolutionWidth + 26), SUM(ResolutionWidth + 27), SUM(ResolutionWidth + 28), SUM(ResolutionWidth + 29), SUM(ResolutionWidth + 30), SUM(ResolutionWidth + 31), SUM(ResolutionWidth + 32), SUM(ResolutionWidth + 33), SUM(ResolutionWidth + 34), SUM(ResolutionWidth + 35), SUM(ResolutionWidth + 36), SUM(ResolutionWidth + 37), SUM(ResolutionWidth + 38), SUM(ResolutionWidth + 39), SUM(ResolutionWidth + 40), SUM(ResolutionWidth + 41), SUM(ResolutionWidth + 42), SUM(ResolutionWidth + 43), SUM(ResolutionWidth + 44), SUM(ResolutionWidth + 45), SUM(ResolutionWidth + 46), SUM(ResolutionWidth + 47), SUM(ResolutionWidth + 48), SUM(ResolutionWidth + 49), SUM(ResolutionWidth + 50), SUM(ResolutionWidth + 51), SUM(ResolutionWidth + 52), SUM(ResolutionWidth + 53), SUM(ResolutionWidth + 54), SUM(ResolutionWidth + 55), SUM(ResolutionWidth + 56), SUM(ResolutionWidth + 57), SUM(ResolutionWidth + 58), SUM(ResolutionWidth + 59), SUM(ResolutionWidth + 60), SUM(ResolutionWidth + 61), SUM(ResolutionWidth + 62), SUM(ResolutionWidth + 63), SUM(ResolutionWidth + 64), SUM(ResolutionWidth + 65), SUM(ResolutionWidth + 66), SUM(ResolutionWidth + 67), SUM(ResolutionWidth + 68), SUM(ResolutionWidth + 69), SUM(ResolutionWidth + 70), SUM(ResolutionWidth + 71), SUM(ResolutionWidth + 72), SUM(ResolutionWidth + 73), SUM(ResolutionWidth + 74), SUM(ResolutionWidth + 75), SUM(ResolutionWidth + 76), SUM(ResolutionWidth + 77), SUM(ResolutionWidth + 78), SUM(ResolutionWidth + 79), SUM(ResolutionWidth + 80), SUM(ResolutionWidth + 81), SUM(ResolutionWidth + 82), SUM(ResolutionWidth + 83), SUM(ResolutionWidth + 84), SUM(ResolutionWidth + 85), SUM(ResolutionWidth + 86), SUM(ResolutionWidth + 87), SUM(ResolutionWidth + 88), SUM(ResolutionWidth + 89) FROM hits;",
        lambda x: x["ResolutionWidth"].sum()
        + x["ResolutionWidth"].shift(1).sum()
        + x["ResolutionWidth"].shift(2).sum()
        + x["ResolutionWidth"].shift(3).sum()
        + x["ResolutionWidth"].shift(4).sum()
        + x["ResolutionWidth"].shift(5).sum()
        + x["ResolutionWidth"].shift(6).sum()
        + x["ResolutionWidth"].shift(7).sum()
        + x["ResolutionWidth"].shift(8).sum()
        + x["ResolutionWidth"].shift(9).sum()
        + x["ResolutionWidth"].shift(10).sum()
        + x["ResolutionWidth"].shift(11).sum()
        + x["ResolutionWidth"].shift(12).sum()
        + x["ResolutionWidth"].shift(13).sum()
        + x["ResolutionWidth"].shift(14).sum()
        + x["ResolutionWidth"].shift(15).sum()
        + x["ResolutionWidth"].shift(16).sum()
        + x["ResolutionWidth"].shift(17).sum()
        + x["ResolutionWidth"].shift(18).sum()
        + x["ResolutionWidth"].shift(19).sum()
        + x["ResolutionWidth"].shift(20).sum()
        + x["ResolutionWidth"].shift(21).sum()
        + x["ResolutionWidth"].shift(22).sum()
        + x["ResolutionWidth"].shift(23).sum()
        + x["ResolutionWidth"].shift(24).sum()
        + x["ResolutionWidth"].shift(25).sum()
        + x["ResolutionWidth"].shift(26).sum()
        + x["ResolutionWidth"].shift(27).sum()
        + x["ResolutionWidth"].shift(28).sum()
        + x["ResolutionWidth"].shift(29).sum()
        + x["ResolutionWidth"].shift(30).sum()
        + x["ResolutionWidth"].shift(31).sum()
        + x["ResolutionWidth"].shift(32).sum()
        + x["ResolutionWidth"].shift(33).sum()
        + x["ResolutionWidth"].shift(34).sum()
        + x["ResolutionWidth"].shift(35).sum()
        + x["ResolutionWidth"].shift(36).sum()
        + x["ResolutionWidth"].shift(37).sum()
        + x["ResolutionWidth"].shift(38).sum()
        + x["ResolutionWidth"].shift(39).sum()
        + x["ResolutionWidth"].shift(40).sum()
        + x["ResolutionWidth"].shift(41).sum()
        + x["ResolutionWidth"].shift(42).sum()
        + x["ResolutionWidth"].shift(43).sum()
        + x["ResolutionWidth"].shift(44).sum()
        + x["ResolutionWidth"].shift(45).sum()
        + x["ResolutionWidth"].shift(46).sum()
        + x["ResolutionWidth"].shift(47).sum()
        + x["ResolutionWidth"].shift(48).sum()
        + x["ResolutionWidth"].shift(49).sum()
        + x["ResolutionWidth"].shift(50).sum()
        + x["ResolutionWidth"].shift(51).sum()
        + x["ResolutionWidth"].shift(52).sum()
        + x["ResolutionWidth"].shift(53).sum()
        + x["ResolutionWidth"].shift(54).sum()
        + x["ResolutionWidth"].shift(55).sum()
        + x["ResolutionWidth"].shift(56).sum()
        + x["ResolutionWidth"].shift(57).sum()
        + x["ResolutionWidth"].shift(58).sum()
        + x["ResolutionWidth"].shift(59).sum()
        + x["ResolutionWidth"].shift(60).sum()
        + x["ResolutionWidth"].shift(61).sum()
        + x["ResolutionWidth"].shift(62).sum()
        + x["ResolutionWidth"].shift(63).sum()
        + x["ResolutionWidth"].shift(64).sum()
        + x["ResolutionWidth"].shift(65).sum()
        + x["ResolutionWidth"].shift(66).sum()
        + x["ResolutionWidth"].shift(67).sum()
        + x["ResolutionWidth"].shift(68).sum()
        + x["ResolutionWidth"].shift(69).sum()
        + x["ResolutionWidth"].shift(70).sum()
        + x["ResolutionWidth"].shift(71).sum()
        + x["ResolutionWidth"].shift(72).sum()
        + x["ResolutionWidth"].shift(73).sum()
        + x["ResolutionWidth"].shift(74).sum()
        + x["ResolutionWidth"].shift(75).sum()
        + x["ResolutionWidth"].shift(76).sum()
        + x["ResolutionWidth"].shift(77).sum()
        + x["ResolutionWidth"].shift(78).sum()
        + x["ResolutionWidth"].shift(79).sum()
        + x["ResolutionWidth"].shift(80).sum()
        + x["ResolutionWidth"].shift(81).sum()
        + x["ResolutionWidth"].shift(82).sum()
        + x["ResolutionWidth"].shift(83).sum()
        + x["ResolutionWidth"].shift(84).sum()
        + x["ResolutionWidth"].shift(85).sum()
        + x["ResolutionWidth"].shift(86).sum()
        + x["ResolutionWidth"].shift(87).sum()
        + x["ResolutionWidth"].shift(88).sum()
        + x["ResolutionWidth"].shift(89).sum(),
        lambda x: x.select(pl.sum_horizontal([pl.col("ResolutionWidth").shift(i) for i in range(1, 90)])).collect(),
    ),
    (
        "Q30",
        "SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["SearchEngineID", "ClientIP"])
        .agg(
            c=("SearchEngineID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .group_by(["SearchEngineID", "ClientIP"])
        .agg(
            [
                pl.len().alias("c"),
                pl.sum("IsRefresh").alias("IsRefreshSum"),
                pl.mean("ResolutionWidth").alias("AvgResolutionWidth"),
            ]
        )
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q31",
        "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x[x["SearchPhrase"] != ""]
        .groupby(["WatchID", "ClientIP"])
        .agg(
            c=("WatchID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
        lambda x: x.filter(pl.col("SearchPhrase") != "")
        .group_by(["WatchID", "ClientIP"])
        .agg(
            [
                pl.len().alias("c"),
                pl.sum("IsRefresh").alias("IsRefreshSum"),
                pl.mean("ResolutionWidth").alias("AvgResolutionWidth"),
            ]
        )
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q32",
        "SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby(["WatchID", "ClientIP"])
        .agg(
            c=("WatchID", "size"),
            IsRefreshSum=("IsRefresh", "sum"),
            AvgResolutionWidth=("ResolutionWidth", "mean"),
        )
        .nlargest(10, "c"),
        lambda x: x.group_by(["WatchID", "ClientIP"])
        .agg(
            [
                pl.len().alias("c"),
                pl.sum("IsRefresh").alias("IsRefreshSum"),
                pl.mean("ResolutionWidth").alias("AvgResolutionWidth"),
            ]
        )
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q33",
        "SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby("URL").size().nlargest(10).reset_index(name="c"),
        lambda x: x.group_by("URL")
        .agg(pl.len().alias("c"))
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q34",
        "SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;",
        lambda x: x.groupby(["URL"]).size().nlargest(10).reset_index(name="c"),
        lambda x: x.group_by("URL")
        .agg(pl.len().alias("c"))
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q35",
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
        lambda x: x.with_columns([pl.col("ClientIP")])
        .group_by(["ClientIP"])
        .agg(pl.len().alias("c"))
        .sort("c", descending=True)
        .head(10).collect(),
    ),
    (
        "Q36",
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
        lambda x: x.filter(
            (pl.col("CounterID") == 62)
            & (pl.col("EventDate") >= datetime(2013, 7, 1))
            & (pl.col("EventDate") <= datetime(2013, 7, 31))
            & (pl.col("DontCountHits") == 0)
            & (pl.col("IsRefresh") == 0)
            & (pl.col("URL") != "")
        )
        .group_by("URL")
        .agg(pl.len().alias("PageViews"))
        .sort("PageViews", descending=True)
        .head(10).collect(),
    ),
    (
        "Q37",
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
        lambda x: x.filter(
            (pl.col("CounterID") == 62)
            & (pl.col("EventDate") >= datetime(2013, 7, 1))
            & (pl.col("EventDate") <= datetime(2013, 7, 31))
            & (pl.col("DontCountHits") == 0)
            & (pl.col("IsRefresh") == 0)
            & (pl.col("Title") != "")
        )
        .group_by("Title")
        .agg(pl.len().alias("PageViews"))
        .sort("PageViews", descending=True)
        .head(10).collect(),
    ),
    (
        "Q38",
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
        lambda x: x.filter(
            (pl.col("CounterID") == 62)
            & (pl.col("EventDate") >= datetime(2013, 7, 1))
            & (pl.col("EventDate") <= datetime(2013, 7, 31))
            & (pl.col("IsRefresh") == 0)
            & (pl.col("IsLink") != 0)
            & (pl.col("IsDownload") == 0)
        )
        .group_by("URL")
        .agg(pl.len().alias("PageViews"))
        .sort("PageViews", descending=True)
        .slice(1000, 10).collect(),
    ),
    (
        "Q39",
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
        lambda x: None,
        # Crash with:
        #   thread '<unnamed>' panicked at crates/polars-time/src/windows/duration.rs:215:21:
        #   expected leading integer in the duration string, found m
        #   note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
        # lambda x: x.filter(
        #     (pl.col("CounterID") == 62)
        #     & (pl.col("EventDate") >= datetime(2013, 7, 1))
        #     & (pl.col("EventDate") <= datetime(2013, 7, 31))
        #     & (pl.col("IsRefresh") == 0)
        # )
        # .group_by(
        #     [
        #         "TraficSourceID",
        #         "SearchEngineID",
        #         "AdvEngineID",
        #         # pl.when(pl.col("SearchEngineID").eq(0) & pl.col("AdvEngineID").eq(0))
        #         # .then(pl.col("Referer"))
        #         # .otherwise("")
        #         # .alias("Src"),
        #         "URL",
        #     ]
        # )
        # .agg(pl.len().alias("PageViews"))
        # .sort("PageViews", descending=True)
        # .slice(1000, 10),
    ),
    (
        "Q40",
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
        lambda x: x.filter(
            (pl.col("CounterID") == 62)
            & (pl.col("EventDate") >= datetime(2013, 7, 1))
            & (pl.col("EventDate") <= datetime(2013, 7, 31))
            & (pl.col("IsRefresh") == 0)
            & (pl.col("TraficSourceID").is_in([-1, 6]))
            & (pl.col("RefererHash") == 3594120000172545465)
        )
        .group_by(["URLHash", "EventDate"])
        .agg(pl.len().alias("PageViews"))
        .sort("PageViews", descending=True)
        .slice(100, 10).collect(),
    ),
    (
        "Q41",
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
        lambda x: x.filter(
            (pl.col("CounterID") == 62)
            & (pl.col("EventDate") >= datetime(2013, 7, 1))
            & (pl.col("EventDate") <= datetime(2013, 7, 31))
            & (pl.col("IsRefresh") == 0)
            & (pl.col("DontCountHits") == 0)
            & (pl.col("URLHash") == 2868770270353813622)
        )
        .group_by(["WindowClientWidth", "WindowClientHeight"])
        .agg(pl.len().alias("PageViews"))
        .sort("PageViews", descending=True)
        .slice(10000, 10).collect(),
    ),
    (
        "Q42",
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
        lambda x: None,
        # Crash with:
        #   thread '<unnamed>' panicked at crates/polars-time/src/windows/duration.rs:215:21:
        #   expected leading integer in the duration string, found m
        # lambda x: x.filter(
        #     (pl.col("CounterID") == 62)
        #     & (pl.col("EventDate") >= datetime(2013, 7, 14))
        #     & (pl.col("EventDate") <= datetime(2013, 7, 15))
        #     & (pl.col("IsRefresh") == 0)
        #     & (pl.col("DontCountHits") == 0)
        # )
        # .group_by(pl.col("EventTime").dt.truncate("minute"))
        # .agg(pl.len().alias("PageViews"))
        # .slice(1000, 10),
    ),
]

queries_times = []
for q in queries:
    times = []
    for _ in range(3):
        start = timeit.default_timer()
        result = q[3](pl_df)
        end = timeit.default_timer()
        if result is None:
            times.append(None)
        else:
            times.append(end - start)
    queries_times.append(times)

result_json = {
    "system": "Polars (DataFrame)",
    "date": date.today().strftime("%Y-%m-%d"),
    "machine": "c6a.metal, 500gb gp2",
    "cluster_size": 1,
    "comment": "",
    "tags": [
        "C++",
        "column-oriented",
        "embedded",
        "stateless",
        "serverless",
        "dataframe",
    ],
    "load_time": float(load_time),
    "data_size": int(dataframe_size),
    "result": queries_times,
}

# if cpuinfo contains "AMD EPYC 9654" update machine and write result into results/epyc-9654.json
if "AMD EPYC 9654" in open("/proc/cpuinfo").read():
    result_json["machine"] = "EPYC 9654, 384G"
    with open("results/epyc-9654.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
else:
    # write result into results/c6a.metal.json
    with open("results/c6a.metal.json", "w") as f:
        f.write(json.dumps(result_json, indent=4))
