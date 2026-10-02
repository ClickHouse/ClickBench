-- Load one deterministic hash bucket. The double modulo maps signed
-- fnv_hash() output into [0, bucket_count), avoiding the -9..-1 trap.
USE clickbench;

UPSERT INTO hits_kudu_raw
SELECT
    WatchID, EventTime, JavaEnable, Title, GoodEvent, EventDate,
    CounterID, ClientIP, RegionID, UserID, CounterClass, OS,
    UserAgent, URL, Referer, IsRefresh, RefererCategoryID, RefererRegionID,
    URLCategoryID, URLRegionID, ResolutionWidth, ResolutionHeight, ResolutionDepth, FlashMajor,
    FlashMinor, FlashMinor2, NetMajor, NetMinor, UserAgentMajor, UserAgentMinor,
    CookieEnable, JavascriptEnable, IsMobile, MobilePhone, MobilePhoneModel, Params,
    IPNetworkID, TraficSourceID, SearchEngineID, SearchPhrase, AdvEngineID, IsArtifical,
    WindowClientWidth, WindowClientHeight, ClientTimeZone, ClientEventTime, SilverlightVersion1, SilverlightVersion2,
    SilverlightVersion3, SilverlightVersion4, PageCharset, CodeVersion, IsLink, IsDownload,
    IsNotBounce, FUniqID, OriginalURL, HID, IsOldCounter, IsEvent,
    IsParameter, DontCountHits, WithHash, HitColor, LocalEventTime, Age,
    Sex, Income, Interests, Robotness, RemoteIP, WindowName,
    OpenerName, HistoryLength, BrowserLanguage, BrowserCountry, SocialNetwork, SocialAction,
    HTTPError, SendTiming, DNSTiming, ConnectTiming, ResponseStartTiming, ResponseEndTiming,
    FetchTiming, SocialSourceNetworkID, SocialSourcePage, ParamPrice, ParamOrderID, ParamCurrency,
    ParamCurrencyID, OpenstatServiceName, OpenstatCampaignID, OpenstatAdID, OpenstatSourceID, UTMSource,
    UTMMedium, UTMCampaign, UTMContent, UTMTerm, FromTag, HasGCLID,
    RefererHash, URLHash, CLID
FROM hits
WHERE ((fnv_hash(WatchID) % __BUCKETS__) + __BUCKETS__) % __BUCKETS__ = __BUCKET__;
