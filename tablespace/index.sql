ALTER TABLE hits ADD CONSTRAINT hits_pkey PRIMARY KEY (CounterID, EventDate, UserID, EventTime, WatchID);
Create index hits_col_idx on hits using columnstore(
    WatchID, AdvEngineID,  ResolutionWidth,  UserID,  SearchPhrase,  EventDate,  RegionID,  MobilePhoneModel,  MobilePhone,
    SearchEngineID,  EventTime, URL,  Title,  CounterID,  Referer,  ClientIP,  DontCountHits,  Refresh,  IsLink,  IsDownload,
    TraficSourceID,  URLHash,  RefererHash,  WindowClientWidth, WindowClientHeight
)
    WITH (
    cluster_by = 'CounterID',
    segment_cluster_by = 'EventDate'
);
CREATE INDEX eventdate on hits (eventdate);
CREATE INDEX userid on hits (userid);
CREATE INDEX useridsearch on hits (userid, searchphrase);
CREATE INDEX search2 on hits (searchphrase) WHERE searchphrase <> ''::text;
CREATE INDEX trgm_idx_title ON hits USING gin (title gin_trgm_ops);
CREATE INDEX trgm_idx_url ON hits USING gin (url gin_trgm_ops);
CREATE INDEX eventtime on hits (eventtime);