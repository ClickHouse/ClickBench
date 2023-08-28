// SELECT COUNT(*) FROM hits;
hits
| summarize Count = count()

// SELECT COUNT(*) FROM hits WHERE AdvEngineID <> 0;
hits
| where AdvEngineID != 0
| summarize Count = count()

// SELECT SUM(AdvEngineID), COUNT(*), AVG(ResolutionWidth) FROM hits;
hits
| summarize SumAdvEngineID = sum(AdvEngineID), Count = count(), AvgResolutionWidth = avg(ResolutionWidth)

// SELECT AVG(UserID) FROM hits;
hits
| summarize AvgUserID = avg(UserID)

// SELECT COUNT(DISTINCT UserID) FROM hits;
hits
| summarize CountDistinctUserID = dcount(UserID)

// SELECT COUNT(DISTINCT SearchPhrase) FROM hits;
hits
| summarize CountDistinctSearchPhrase = dcount(SearchPhrase)

// SELECT MIN(EventDate), MAX(EventDate) FROM hits;
hits
| summarize MinEventDate = min(EventDate), MaxEventDate = max(EventDate)

// SELECT AdvEngineID, COUNT(*) FROM hits WHERE AdvEngineID <> 0 GROUP BY AdvEngineID ORDER BY COUNT(*) DESC;
hits
| where AdvEngineID != 0
| summarize Count = count() by AdvEngineID
| order by Count desc

// SELECT RegionID, COUNT(DISTINCT UserID) AS u FROM hits GROUP BY RegionID ORDER BY u DESC LIMIT 10;
hits
| summarize u = dcount(UserID) by RegionID
| order by u desc 
| take 10

// SELECT RegionID, SUM(AdvEngineID), COUNT(*) AS c, AVG(ResolutionWidth), COUNT(DISTINCT UserID) FROM hits GROUP BY RegionID ORDER BY c DESC LIMIT 10;
hits
| summarize SumAdvEngineID = sum(AdvEngineID), c = count(), AvgResolutionWidth = avg(ResolutionWidth), CountDistinctUserID = dcount(UserID) by RegionID
| order by c desc
| take 10

// SELECT MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhoneModel ORDER BY u DESC LIMIT 10;
hits
| where MobilePhoneModel != ""
| summarize u = dcount(UserID) by MobilePhoneModel
| order by u desc
| take 10

// SELECT MobilePhone, MobilePhoneModel, COUNT(DISTINCT UserID) AS u FROM hits WHERE MobilePhoneModel <> '' GROUP BY MobilePhone, MobilePhoneModel ORDER BY u DESC LIMIT 10;
hits
| where MobilePhoneModel != ""
| summarize u = dcount(UserID) by MobilePhone, MobilePhoneModel
| order by u desc
| take 10

// SELECT SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
hits
| where SearchPhrase != ""
| summarize c = count() by SearchPhrase
| order by c desc
| take 10

// SELECT SearchPhrase, COUNT(DISTINCT UserID) AS u FROM hits WHERE SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY u DESC LIMIT 10;
hits
| where SearchPhrase != ""
| summarize u = dcount(UserID) by SearchPhrase
| order by u desc
| take 10

// SELECT SearchEngineID, SearchPhrase, COUNT(*) AS c FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, SearchPhrase ORDER BY c DESC LIMIT 10;
hits
| where SearchPhrase != ""
| summarize c = count() by SearchEngineID, SearchPhrase
| order by c desc
| take 10

// SELECT UserID, COUNT(*) FROM hits GROUP BY UserID ORDER BY COUNT(*) DESC LIMIT 10;
hits
| summarize c = count() by UserID
| order by c desc
| take 10

// SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;
hits
| summarize c = count() by UserID, SearchPhrase
| order by c desc
| take 10

// SELECT UserID, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, SearchPhrase LIMIT 10;
hits
| summarize c = count() by UserID, SearchPhrase
| take 10

// SELECT UserID, extract(minute FROM EventTime) AS m, SearchPhrase, COUNT(*) FROM hits GROUP BY UserID, m, SearchPhrase ORDER BY COUNT(*) DESC LIMIT 10;
hits
| extend m = datetime_part("Minute", EventTime)
| summarize c = count() by UserID, m, SearchPhrase
| order by c desc
| take 10

// SELECT UserID FROM hits WHERE UserID = 435090932899640449;
hits
| where UserID == 435090932899640449
| project UserID


// SELECT COUNT(*) FROM hits WHERE URL LIKE '%google%';
hits
| where URL contains "google"
| summarize Count = count()

// SELECT SearchPhrase, MIN(URL), COUNT(*) AS c FROM hits WHERE URL LIKE '%google%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
hits
| where URL contains "google" and SearchPhrase != ""
| summarize c = count(), MinURL = min(URL) by SearchPhrase
| order by c desc
| take 10

// SELECT SearchPhrase, MIN(URL), MIN(Title), COUNT(*) AS c, COUNT(DISTINCT UserID) FROM hits WHERE Title LIKE '%Google%' AND URL NOT LIKE '%.google.%' AND SearchPhrase <> '' GROUP BY SearchPhrase ORDER BY c DESC LIMIT 10;
hits
| where Title contains "Google" and URL !contains ".google." and SearchPhrase != ""
| summarize c = count(), MinURL = min(URL), MinTitle = min(Title), CountDistinctUserID = dcount(UserID) by SearchPhrase
| order by c desc
| take 10

// SELECT * FROM hits WHERE URL LIKE '%google%' ORDER BY EventTime LIMIT 10;
hits
| where URL contains "google"
| project *
| order by EventTime
| take 10

// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime LIMIT 10;
hits
| where SearchPhrase != ""
| project SearchPhrase
| order by EventTime
| take 10

// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY SearchPhrase LIMIT 10;
hits
| where SearchPhrase != ""
| project SearchPhrase
| order by SearchPhrase
| take 10

// SELECT SearchPhrase FROM hits WHERE SearchPhrase <> '' ORDER BY EventTime, SearchPhrase LIMIT 10;
hits
| where SearchPhrase != ""
| project SearchPhrase
| order by EventTime, SearchPhrase
| take 10

// SELECT CounterID, AVG(length(URL)) AS l, COUNT(*) AS c FROM hits WHERE URL <> '' GROUP BY CounterID HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
hits
| where URL != ""
| summarize c = count(), l = avg(strlen(URL)) by CounterID
| where c > 100000
| order by l desc
| take 25

// SELECT REGEXP_REPLACE(Referer, '^https?://(?:www\.)?([^/]+)/.*$', '\1') AS k, AVG(length(Referer)) AS l, COUNT(*) AS c, MIN(Referer) FROM hits WHERE Referer <> '' GROUP BY k HAVING COUNT(*) > 100000 ORDER BY l DESC LIMIT 25;
hits
| where Referer != ""
| extend k = extract(@"^https?://(?:www\.)?([^/]+)/.*$", 1, Referer)
| summarize l = avg(strlen(Referer)), c = count(), MinReferer = min(Referer) by k
| where c > 100000
| order by l desc
| take 25

// SELECT SUM(ResolutionWidth), SUM(ResolutionWidth + 1), SUM(ResolutionWidth + 2), SUM(ResolutionWidth + 3), SUM(ResolutionWidth + 4), SUM(ResolutionWidth + 5), SUM(ResolutionWidth + 6), SUM(ResolutionWidth + 7), SUM(ResolutionWidth + 8), SUM(ResolutionWidth + 9), SUM(ResolutionWidth + 10), SUM(ResolutionWidth + 11), SUM(ResolutionWidth + 12), SUM(ResolutionWidth + 13), SUM(ResolutionWidth + 14), SUM(ResolutionWidth + 15), SUM(ResolutionWidth + 16), SUM(ResolutionWidth + 17), SUM(ResolutionWidth + 18), SUM(ResolutionWidth + 19), SUM(ResolutionWidth + 20), SUM(ResolutionWidth + 21), SUM(ResolutionWidth + 22), SUM(ResolutionWidth + 23), SUM(ResolutionWidth + 24), SUM(ResolutionWidth + 25), SUM(ResolutionWidth + 26), SUM(ResolutionWidth + 27), SUM(ResolutionWidth + 28), SUM(ResolutionWidth + 29), SUM(ResolutionWidth + 30), SUM(ResolutionWidth + 31), SUM(ResolutionWidth + 32), SUM(ResolutionWidth + 33), SUM(ResolutionWidth + 34), SUM(ResolutionWidth + 35), SUM(ResolutionWidth + 36), SUM(ResolutionWidth + 37), SUM(ResolutionWidth + 38), SUM(ResolutionWidth + 39), SUM(ResolutionWidth + 40), SUM(ResolutionWidth + 41), SUM(ResolutionWidth + 42), SUM(ResolutionWidth + 43), SUM(ResolutionWidth + 44), SUM(ResolutionWidth + 45), SUM(ResolutionWidth + 46), SUM(ResolutionWidth + 47), SUM(ResolutionWidth + 48), SUM(ResolutionWidth + 49), SUM(ResolutionWidth + 50), SUM(ResolutionWidth + 51), SUM(ResolutionWidth + 52), SUM(ResolutionWidth + 53), SUM(ResolutionWidth + 54), SUM(ResolutionWidth + 55), SUM(ResolutionWidth + 56), SUM(ResolutionWidth + 57), SUM(ResolutionWidth + 58), SUM(ResolutionWidth + 59), SUM(ResolutionWidth + 60), SUM(ResolutionWidth + 61), SUM(ResolutionWidth + 62), SUM(ResolutionWidth + 63), SUM(ResolutionWidth + 64), SUM(ResolutionWidth + 65), SUM(ResolutionWidth + 66), SUM(ResolutionWidth + 67), SUM(ResolutionWidth + 68), SUM(ResolutionWidth + 69), SUM(ResolutionWidth + 70), SUM(ResolutionWidth + 71), SUM(ResolutionWidth + 72), SUM(ResolutionWidth + 73), SUM(ResolutionWidth + 74), SUM(ResolutionWidth + 75), SUM(ResolutionWidth + 76), SUM(ResolutionWidth + 77), SUM(ResolutionWidth + 78), SUM(ResolutionWidth + 79), SUM(ResolutionWidth + 80), SUM(ResolutionWidth + 81), SUM(ResolutionWidth + 82), SUM(ResolutionWidth + 83), SUM(ResolutionWidth + 84), SUM(ResolutionWidth + 85), SUM(ResolutionWidth + 86), SUM(ResolutionWidth + 87), SUM(ResolutionWidth + 88), SUM(ResolutionWidth + 89) FROM hits;
hits
| summarize 
    sum0 = sum(ResolutionWidth),
    sum1 = sum(ResolutionWidth + 1),
    sum2 = sum(ResolutionWidth + 2),
    sum3 = sum(ResolutionWidth + 3),
    sum4 = sum(ResolutionWidth + 4),
    sum5 = sum(ResolutionWidth + 5),
    sum6 = sum(ResolutionWidth + 6),
    sum7 = sum(ResolutionWidth + 7),
    sum8 = sum(ResolutionWidth + 8),
    sum9 = sum(ResolutionWidth + 9),
    sum10 = sum(ResolutionWidth + 10),
    sum11 = sum(ResolutionWidth + 11),
    sum12 = sum(ResolutionWidth + 12),
    sum13 = sum(ResolutionWidth + 13),
    sum14 = sum(ResolutionWidth + 14),
    sum15 = sum(ResolutionWidth + 15),
    sum16 = sum(ResolutionWidth + 16),
    sum17 = sum(ResolutionWidth + 17),
    sum18 = sum(ResolutionWidth + 18),
    sum19 = sum(ResolutionWidth + 19),
    sum20 = sum(ResolutionWidth + 20),
    sum21 = sum(ResolutionWidth + 21),
    sum22 = sum(ResolutionWidth + 22),
    sum23 = sum(ResolutionWidth + 23),
    sum24 = sum(ResolutionWidth + 24),
    sum25 = sum(ResolutionWidth + 25),
    sum26 = sum(ResolutionWidth + 26),
    sum27 = sum(ResolutionWidth + 27),
    sum28 = sum(ResolutionWidth + 28),
    sum29 = sum(ResolutionWidth + 29),
    sum30 = sum(ResolutionWidth + 30),
    sum31 = sum(ResolutionWidth + 31),
    sum32 = sum(ResolutionWidth + 32),
    sum33 = sum(ResolutionWidth + 33),
    sum34 = sum(ResolutionWidth + 34),
    sum35 = sum(ResolutionWidth + 35),
    sum36 = sum(ResolutionWidth + 36),
    sum37 = sum(ResolutionWidth + 37),
    sum38 = sum(ResolutionWidth + 38),
    sum39 = sum(ResolutionWidth + 39),
    sum40 = sum(ResolutionWidth + 40),
    sum41 = sum(ResolutionWidth + 41),
    sum42 = sum(ResolutionWidth + 42),
    sum43 = sum(ResolutionWidth + 43),
    sum44 = sum(ResolutionWidth + 44),
    sum45 = sum(ResolutionWidth + 45),
    sum46 = sum(ResolutionWidth + 46),
    sum47 = sum(ResolutionWidth + 47),
    sum48 = sum(ResolutionWidth + 48),
    sum49 = sum(ResolutionWidth + 49),
    sum50 = sum(ResolutionWidth + 50),
    sum51 = sum(ResolutionWidth + 51),
    sum52 = sum(ResolutionWidth + 52),
    sum53 = sum(ResolutionWidth + 53),
    sum54 = sum(ResolutionWidth + 54),
    sum55 = sum(ResolutionWidth + 55),
    sum56 = sum(ResolutionWidth + 56),
    sum57 = sum(ResolutionWidth + 57),
    sum58 = sum(ResolutionWidth + 58),
    sum59 = sum(ResolutionWidth + 59),
    sum60 = sum(ResolutionWidth + 60),
    sum61 = sum(ResolutionWidth + 61),
    sum62 = sum(ResolutionWidth + 62),
    sum63 = sum(ResolutionWidth + 63),
    sum64 = sum(ResolutionWidth + 64),
    sum65 = sum(ResolutionWidth + 65),
    sum66 = sum(ResolutionWidth + 66),
    sum67 = sum(ResolutionWidth + 67),
    sum68 = sum(ResolutionWidth + 68),
    sum69 = sum(ResolutionWidth + 69),
    sum70 = sum(ResolutionWidth + 70),
    sum71 = sum(ResolutionWidth + 71),
    sum72 = sum(ResolutionWidth + 72),
    sum73 = sum(ResolutionWidth + 73),
    sum74 = sum(ResolutionWidth + 74),
    sum75 = sum(ResolutionWidth + 75),
    sum76 = sum(ResolutionWidth + 76),
    sum77 = sum(ResolutionWidth + 77),
    sum78 = sum(ResolutionWidth + 78),
    sum79 = sum(ResolutionWidth + 79),
    sum80 = sum(ResolutionWidth + 80),
    sum81 = sum(ResolutionWidth + 81),
    sum82 = sum(ResolutionWidth + 82),
    sum83 = sum(ResolutionWidth + 83),
    sum84 = sum(ResolutionWidth + 84),
    sum85 = sum(ResolutionWidth + 85),
    sum86 = sum(ResolutionWidth + 86),
    sum87 = sum(ResolutionWidth + 87),
    sum88 = sum(ResolutionWidth + 88),
    sum89 = sum(ResolutionWidth + 89)

// SELECT SearchEngineID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY SearchEngineID, ClientIP ORDER BY c DESC LIMIT 10;
hits
| where SearchPhrase != ''
| summarize c=count(), SumIsRefresh=sum(IsRefresh), AvgResolutionWidth=avg(ResolutionWidth) by SearchEngineID, ClientIP
| order by c desc
| take 10

// SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits WHERE SearchPhrase <> '' GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;
hits
| where SearchPhrase != ''
| summarize c=count(), SumIsRefresh=sum(IsRefresh), AvgResolutionWidth=avg(ResolutionWidth) by WatchID, ClientIP
| order by c desc
| take 10

// SELECT WatchID, ClientIP, COUNT(*) AS c, SUM(IsRefresh), AVG(ResolutionWidth) FROM hits GROUP BY WatchID, ClientIP ORDER BY c DESC LIMIT 10;
hits
| summarize c=count(), SumIsRefresh=sum(IsRefresh), AvgResolutionWidth=avg(ResolutionWidth) by WatchID, ClientIP
| order by c desc
| take 10

// SELECT URL, COUNT(*) AS c FROM hits GROUP BY URL ORDER BY c DESC LIMIT 10;
hits
| summarize c=count() by URL
| order by c desc
| take 10

// SELECT 1, URL, COUNT(*) AS c FROM hits GROUP BY 1, URL ORDER BY c DESC LIMIT 10;
hits
| summarize c=count() by URL
| extend DummyColumn=1
| order by c desc
| take 10

// SELECT ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3, COUNT(*) AS c FROM hits GROUP BY ClientIP, ClientIP - 1, ClientIP - 2, ClientIP - 3 ORDER BY c DESC LIMIT 10;
hits
| extend ClientIP_1=ClientIP - 1, ClientIP_2=ClientIP - 2, ClientIP_3=ClientIP - 3
| summarize c=count() by ClientIP, ClientIP_1, ClientIP_2, ClientIP_3
| order by c desc
| take 10

// SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND URL <> '' GROUP BY URL ORDER BY PageViews DESC LIMIT 10;
hits
| where CounterID == 62 and EventDate between (datetime('2013-07-01') .. datetime('2013-07-31')) and DontCountHits == 0 and IsRefresh == 0 and URL != ''
| summarize PageViews=count() by URL
| order by PageViews desc
| take 10

// SELECT Title, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND DontCountHits = 0 AND IsRefresh = 0 AND Title <> '' GROUP BY Title ORDER BY PageViews DESC LIMIT 10;
hits
| where CounterID == 62 and EventDate between (datetime('2013-07-01') .. datetime('2013-07-31')) and DontCountHits == 0 and IsRefresh == 0 and Title != ''
| summarize PageViews=count() by Title
| order by PageViews desc
| take 10

// SELECT URL, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND IsLink <> 0 AND IsDownload = 0 GROUP BY URL ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
hits
| where CounterID == 62 and EventDate between (datetime('2013-07-01') .. datetime('2013-07-31')) and IsRefresh == 0 and IsLink != 0 and IsDownload == 0
| summarize PageViews=count() by URL
| order by PageViews desc
| skip 1000
| take 10

// SELECT TraficSourceID, SearchEngineID, AdvEngineID, CASE WHEN (SearchEngineID = 0 AND AdvEngineID = 0) THEN Referer ELSE '' END AS Src, URL AS Dst, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 GROUP BY TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst ORDER BY PageViews DESC LIMIT 10 OFFSET 1000;
hits 
| where CounterID == 62 and EventDate between(datetime('2013-07-01') .. datetime('2013-07-31')) and IsRefresh == 0
| extend Src = iif(SearchEngineID == 0 and AdvEngineID == 0, Referer, '')
| extend Dst = URL
| summarize PageViews=count() by TraficSourceID, SearchEngineID, AdvEngineID, Src, Dst
| order by PageViews desc
| skip 1000
| take 10

// SELECT URLHash, EventDate, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND TraficSourceID IN (-1, 6) AND RefererHash = 3594120000172545465 GROUP BY URLHash, EventDate ORDER BY PageViews DESC LIMIT 10 OFFSET 100;
hits
| where CounterID == 62 and EventDate between(datetime('2013-07-01') .. datetime('2013-07-31')) and IsRefresh == 0 and TraficSourceID in (-1, 6) and RefererHash == 3594120000172545465
| summarize PageViews=count() by URLHash, EventDate
| order by PageViews desc
| skip 100
| take 10

// SELECT WindowClientWidth, WindowClientHeight, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-01' AND EventDate <= '2013-07-31' AND IsRefresh = 0 AND DontCountHits = 0 AND URLHash = 2868770270353813622 GROUP BY WindowClientWidth, WindowClientHeight ORDER BY PageViews DESC LIMIT 10 OFFSET 10000;
hits
| where CounterID == 62 and EventDate between(datetime('2013-07-01') .. datetime('2013-07-31')) and IsRefresh == 0 and DontCountHits == 0 and URLHash == 2868770270353813622
| summarize PageViews=count() by WindowClientWidth, WindowClientHeight
| order by PageViews desc
| skip 10000
| take 10

// SELECT DATE_TRUNC('minute', EventTime) AS M, COUNT(*) AS PageViews FROM hits WHERE CounterID = 62 AND EventDate >= '2013-07-14' AND EventDate <= '2013-07-15' AND IsRefresh = 0 AND DontCountHits = 0 GROUP BY DATE_TRUNC('minute', EventTime) ORDER BY DATE_TRUNC('minute', EventTime) LIMIT 10 OFFSET 1000;
hits
| where CounterID == 62 and EventDate between(datetime('2013-07-14') .. datetime('2013-07-15')) and IsRefresh == 0 and DontCountHits == 0
| summarize PageViews=count() by M=bin(EventTime, 1m)
| order by M
| skip 1000
| take 10
