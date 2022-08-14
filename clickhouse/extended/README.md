# ClickBench Amplified 1000 Times

This is not part of the normal ClickBench.

These are the files for the extended version of the benchmark (based on the Hardware benchmark) with 100 billion records and 10 TB of data, amplified from the source dataset with the `clickhouse-obfuscator` tool.

This is needed to test the performance of ClickHouse Cloud.

# How to generate the data

```
export STRUCTURE='WatchID UInt64, JavaEnable UInt8, Title String, GoodEvent Int16, EventTime DateTime, EventDate Date, CounterID UInt32, ClientIP UInt32, RegionID UInt32, UserID UInt64, CounterClass Int8, OS UInt8, UserAgent UInt8, URL String, Referer String, Refresh UInt8, RefererCategoryID UInt16, RefererRegionID UInt32, URLCategoryID UInt16, URLRegionID UInt32, ResolutionWidth UInt16, ResolutionHeight UInt16, ResolutionDepth UInt8, FlashMajor UInt8, FlashMinor UInt8, FlashMinor2 String, NetMajor UInt8, NetMinor UInt8, UserAgentMajor UInt16, UserAgentMinor FixedString(2), CookieEnable UInt8, JavascriptEnable UInt8, IsMobile UInt8, MobilePhone UInt8, MobilePhoneModel String, Params String, IPNetworkID UInt32, TraficSourceID Int8, SearchEngineID UInt16, SearchPhrase String, AdvEngineID UInt8, IsArtifical UInt8, WindowClientWidth UInt16, WindowClientHeight UInt16, ClientTimeZone Int16, ClientEventTime DateTime, SilverlightVersion1 UInt8, SilverlightVersion2 UInt8, SilverlightVersion3 UInt32, SilverlightVersion4 UInt16, PageCharset String, CodeVersion UInt32, IsLink UInt8, IsDownload UInt8, IsNotBounce UInt8, FUniqID UInt64, OriginalURL String, HID UInt32, IsOldCounter UInt8, IsEvent UInt8, IsParameter UInt8, DontCountHits UInt8, WithHash UInt8, HitColor FixedString(1), LocalEventTime DateTime, Age UInt8, Sex UInt8, Income UInt8, Interests UInt16, Robotness UInt8, RemoteIP UInt32, WindowName Int32, OpenerName Int32, HistoryLength Int16, BrowserLanguage FixedString(2), BrowserCountry FixedString(2), SocialNetwork String, SocialAction String, HTTPError UInt16, SendTiming UInt32, DNSTiming UInt32, ConnectTiming UInt32, ResponseStartTiming UInt32, ResponseEndTiming UInt32, FetchTiming UInt32, SocialSourceNetworkID UInt8, SocialSourcePage String, ParamPrice Int64, ParamOrderID String, ParamCurrency FixedString(3), ParamCurrencyID UInt16, OpenstatServiceName String, OpenstatCampaignID String, OpenstatAdID String, OpenstatSourceID String, UTMSource String, UTMMedium String, UTMCampaign String, UTMContent String, UTMTerm String, FromTag String, HasGCLID UInt8, RefererHash UInt64, URLHash UInt64, CLID UInt32'

export SEED="${RANDOM}${RANDOM}${RANDOM}${RANDOM}"

clickhouse-obfuscator --structure "${STRUCTURE}" --input-format Native --output-format Native --seed "${SEED}" --limit 0 --save model.bin < hits.native

clickhouse-obfuscator --structure "${STRUCTURE}" --input-format Native --output-format Native --seed "${SEED}" --load model.bin --limit 1000000000000 < hits.native |
    clickhouse-local --structure "${STRUCTURE}" --input-format Native --output-format Native --query "
        SELECT * REPLACE(nowInBlock() AS EventTime, toDate(nowInBlock()) AS EventDate) FROM table" |
    clickhouse-client --host xyz.eu-central-1.aws.clickhouse.cloud --secure --password xyz --query "INSERT INTO hits FORMAT Native"
```

Prepare the list of CounterIDs:

```
SELECT CounterID, count() AS c FROM hits GROUP BY CounterID HAVING c >= 1000000 ORDER BY c DESC INTO OUTFILE 'counters.tsv'
```
