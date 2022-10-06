// SQL comment above each query is from the 'clickhouse' queries.sql file as a reference
queries = [];

// Q0
// SELECT COUNT(*) FROM hits;
queries.push([{ $count: "c" }]);

// Q1
// SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;
queries.push([{ $match: { AdvEngineID: { $ne: 0 } } }, { $count: "c" }]);

// Q2
// SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;
queries.push([
  {
    $group: {
      _id: null,
      sum_AdvEngineID: { $sum: "$AdvEngineID" },
      c: { $sum: 1 },
      avg_ResolutionWidth: { $avg: "$ResolutionWidth" },
    },
  },
]);

// Q3
// SELECT AVG(UserID) FROM hits;
// REMARKS: Precision is lost without the $toDecimal
queries.push([
  { $addFields: { converted: { $toDecimal: "$UserID" } } },
  { $group: { _id: null, a: { $avg: "$converted" } } },
]);

// Q4
// SELECT COUNT(DISTINCT UserID) FROM hits;
queries.push([{ $group: { _id: "$UserID" } }, { $count: "c" }]);

// Q5
// SELECT COUNT(DISTINCT SearchPhrase) FROM hits;
queries.push([{ $group: { _id: "$SearchPhrase" } }, { $count: "c" }]);

// Q6
// SELECT MIN(EventDate), MAX(EventDate) FROM hits;
queries.push([
  {
    $group: {
      _id: null,
      min: { $min: "$EventDate" },
      max: { $max: "$EventDate" },
    },
  },
]);

// Q7
// SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;
queries.push([
  { $match: { AdvEngineID: { $ne: 0 } } },
  { $group: { _id: "$AdvEngineID", c: { $sum: 1 } } },
  { $sort: { c: -1 } },
]);

// Q8
// SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;
queries.push([
  { $group: { _id: { RegionID: "$RegionID", UserID: "$UserID" } } },
  { $group: { _id: "$_id.RegionID", u: { $sum: 1 } } },
  { $sort: { u: -1 } },
  { $limit: 10 },
]);

// Q9
// SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;
queries.push([
  {
    $group: {
      _id: "$RegionID",
      count_distinct_UserID: { $addToSet: "$UserID" },
      sum_AdvEngineID: { $sum: "$AdvEngineID" },
      c: { $sum: 1 },
      avg_ResolutionWidth: { $avg: "$ResolutionWidth" },
    },
  },
  { $set: { count_distinct_UserID: { $size: "$count_distinct_UserID" } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q10
// SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;
queries.push([
  { $match: { MobilePhoneModel: { $ne: "" } } },
  {
    $group: {
      _id: { MobilePhoneModel: "$MobilePhoneModel", UserID: "$UserID" },
    },
  },
  { $group: { _id: "$_id.MobilePhoneModel", u: { $sum: 1 } } },
  { $sort: { u: -1 } },
  { $limit: 10 },
]);

// Q11
// SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;
queries.push([
  { $match: { MobilePhoneModel: { $ne: "" } } },
  {
    $group: {
      _id: {
        MobilePhone: "$MobilePhone",
        MobilePhoneModel: "$MobilePhoneModel",
        UserID: "$UserID",
      },
    },
  },
  {
    $group: {
      _id: {
        MobilePhone: "$_id.MobilePhone",
        MobilePhoneModel: "$_id.MobilePhoneModel",
      },
      u: { $sum: 1 },
    },
  },
  { $sort: { u: -1 } },
  { $limit: 10 },
]);

// Q12
// SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  { $group: { _id: "$SearchPhrase", c: { $sum: 1 } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q13
// SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  { $group: { _id: { SearchPhrase: "$SearchPhrase", UserID: "$UserID" } } },
  { $group: { _id: "$_id.SearchPhrase", u: { $sum: 1 } } },
  { $sort: { u: -1 } },
  { $limit: 10 },
]);

// Q14
// SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  {
    $group: {
      _id: {
        SearchEngineID: "$SearchEngineID",
        SearchPhrase: "$SearchPhrase",
      },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q15
// SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;
queries.push([
  { $group: { _id: "$UserID", c: { $sum: 1 } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q16
// SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;
queries.push([
  {
    $group: {
      _id: { UserID: "$UserID", SearchPhrase: "$SearchPhrase" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q17
// SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;
queries.push([
  {
    $group: {
      _id: { UserID: "$UserID", SearchPhrase: "$SearchPhrase" },
      c: { $sum: 1 },
    },
  },
  { $limit: 10 },
]);

// Q18
// SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;
queries.push([
  { $set: { m: { $minute: "$EventTime" } } },
  {
    $group: {
      _id: { UserID: "$UserID", SearchPhrase: "$SearchPhrase", m: "$m" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q19
// SELECT UserID FROM hits WHERE UserID = 435090932899640449;
queries.push([
  { $match: { UserID: NumberLong("435090932899640449") } },
  { $project: { UserID: 1 } },
]);

// Q20
// SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';
queries.push([{ $match: { URL: /google/ } }, { $count: "c" }]);

// Q21
// SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
queries.push([
  { $match: { URL: /google/, SearchPhrase: { $ne: "" } } },
  {
    $group: {
      _id: "$SearchPhrase",
      min_URL: { $min: "$URL" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q22
// SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
queries.push([
  {
    $match: {
      Title: /Google/,
      URL: { $not: /\\.google\\./ },
      SearchPhrase: { $ne: "" },
    },
  },
  {
    $group: {
      _id: "$SearchPhrase",
      count_distinct_UserID: { $addToSet: "$UserID" },
      min_Title: { $min: "$Title" },
      min_URL: { $min: "$URL" },
      c: { $sum: 1 },
    },
  },
  { $set: { count_distinct_UserID: { $size: "$count_distinct_UserID" } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q23
// SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
queries.push([
  { $match: { URL: /google/ } },
  { $sort: { EventTime: 1 } },
  { $limit: 10 },
]);

// Q24
// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  { $sort: { EventTime: 1 } },
  { $project: { SearchPhrase: 1 } },
  { $limit: 10 },
]);

// Q25
// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  { $sort: { SearchPhrase: 1 } },
  { $project: { SearchPhrase: 1 } },
  { $limit: 10 },
]);

// Q26
// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  { $sort: { EventTime: 1, SearchPhrase: 1 } },
  { $project: { SearchPhrase: 1 } },
  { $limit: 10 },
]);

// Q27
// SELECT CounterID, AVG(length(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
// REMARK: 'LENGTH' seems to be specified as length in bytes, so translated to $strLenBytes, length in characters would be $strLenCP
queries.push([
  { $match: { URL: { $ne: "" } } },
  {
    $group: {
      _id: "$CounterID",
      l: { $avg: { $strLenBytes: "$URL" } },
      c: { $sum: 1 },
    },
  },
  { $match: { c: { $gt: 100000 } } },
  { $sort: { l: -1, SearchPhrase: 1 } },
  { $limit: 25 },
]);

// Q28
// SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1') AS k, AVG(length(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
// REMARK: This seems right but unsure of correct output for this one (mysql results seem strange)
queries.push([
  { $match: { Referer: { $ne: "" } } },
  {
    $set: {
      k: {
        $regexFind: {
          input: "$Referer",
          regex: "^https?://(?:www.)?([^/]+)/.*$",
        },
      },
    },
  },
  { $set: { k: { $ifNull: [{ $first: "$k.captures" }, "$Referer"] } } },
  {
    $group: {
      _id: "$k",
      l: { $avg: { $strLenBytes: "$Referer" } },
      c: { $sum: 1 },
    },
  },
  { $match: { c: { $gt: 100000 } } },
  { $sort: { l: -1, SearchPhrase: 1 } },
  { $limit: 25 },
]);

// Q29
// SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), ..., SUM(ResolutionWidth + 89) FROM hits;
let sums = { _id: null };
for (i = 0; i < 90; ++i) {
  sums["srw_plus_" + i] = {
    $sum: { $toLong: { $add: ["$ResolutionWidth", i] } },
  };
}
queries.push([{ $group: sums }]);

// Q30
// SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  {
    $group: {
      _id: { SearchEngineID: "$SearchEngineID", ClientIP: "$ClientIP" },
      avg_ResolutionWidth: { $avg: "$ResolutionWidth" },
      sum_IsRefresh: { $sum: "$IsRefresh" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q31
// SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;
queries.push([
  { $match: { SearchPhrase: { $ne: "" } } },
  {
    $group: {
      _id: { WatchID: "$WatchID", ClientIP: "$ClientIP" },
      avg_ResolutionWidth: { $avg: "$ResolutionWidth" },
      sum_IsRefresh: { $sum: "$IsRefresh" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q32
// SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;
queries.push([
  {
    $group: {
      _id: { WatchID: "$WatchID", ClientIP: "$ClientIP" },
      avg_ResolutionWidth: { $avg: "$ResolutionWidth" },
      sum_IsRefresh: { $sum: "$IsRefresh" },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q33
// SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;
queries.push([
  { $group: { _id: "$URL", c: { $sum: 1 } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q34
// SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;
queries.push([
  { $group: { _id: { one: { $literal: 1 }, URL: "$URL" }, c: { $sum: 1 } } },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q35
// SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10;
queries.push([
  {
    $group: {
      _id: {
        c_0: "$ClientIP",
        c_1: { $add: ["$ClientIP", -1] },
        c_2: { $add: ["$ClientIP", -2] },
        c_3: { $add: ["$ClientIP", -3] },
      },
      c: { $sum: 1 },
    },
  },
  { $sort: { c: -1 } },
  { $limit: 10 },
]);

// Q36
// SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      DontCountHits: 0,
      IsRefresh: 0,
      URL: { $ne: "" },
    },
  },
  {
    $group: {
      _id: "$URL",
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $limit: 10 },
]);

// Q37
// SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      DontCountHits: 0,
      IsRefresh: 0,
      URL: { $ne: "" },
    },
  },
  {
    $group: {
      _id: "$Title",
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $limit: 10 },
]);

// Q38
// SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      IsRefresh: 0,
      IsLink: { $ne: 0 },
      IsDownload: 0,
      URL: { $ne: "" },
    },
  },
  {
    $group: {
      _id: "$Title",
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $skip: 1000 },
  { $limit: 10 },
]);

// Q39
// SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      IsRefresh: 0,
    },
  },
  {
    $set: {
      Src: {
        $cond: {
          if: {
            $and: [
              { $eq: ["$SearchEngineID", 0] },
              { $eq: ["$AdvEngineID", 0] },
            ],
          },
          then: "$Referer",
          else: "",
        },
      },
      Dst: "$URL",
    },
  },
  {
    $group: {
      _id: {
        TraficSourceID: "$TraficSourceID",
        SearchEngineID: "$SearchEngineID",
        AdvEngineID: "$AdvEngineID",
        Src: "$Src",
        Dst: "$Dst",
      },
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $skip: 1000 },
  { $limit: 10 },
]);

// Q40
// SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      IsRefresh: 0,
      TraficSourceID: { $in: [-1, 6] },
      RefererHash: NumberLong("3594120000172545465"),
    },
  },
  {
    $group: {
      _id: {
        URLHash: "$URLHash",
        EventDate: "$EventDate",
      },
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $skip: 100 },
  { $limit: 10 },
]);

// Q41
// SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-01"), $lte: ISODate("2013-07-31") },
      IsRefresh: 0,
      DontCountHits: 0,
      URLHash: NumberLong("2868770270353813622"),
    },
  },
  {
    $group: {
      _id: {
        WindowClientWidth: "$WindowClientWidth",
        WindowClientHeight: "$WindowClientHeight",
      },
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { pageViews: -1 } },
  { $skip: 10000 },
  { $limit: 10 },
]);

// Q42
// SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000;
queries.push([
  {
    $match: {
      CounterID: 62,
      EventDate: { $gte: ISODate("2013-07-14"), $lte: ISODate("2013-07-15") },
      IsRefresh: 0,
      DontCountHits: 0,
    },
  },
  {
    $set: {
      m: { $dateTrunc: { date: "$EventTime", unit: "minute" } },
    },
  },
  {
    $group: {
      _id: "$m",
      pageViews: { $sum: 1 },
    },
  },
  { $sort: { _id: 1 } },
  { $skip: 1000 },
  { $limit: 10 },
]);
