CREATE INDEX adveng on hits (AdvEngineID);
CREATE INDEX regid  on hits (RegionID);
CREATE INDEX cid on hits (CounterID);
CREATE INDEX eventtime on hits (EventTime);
CREATE INDEX eventdate on hits (EventDate);
CREATE INDEX mobile on hits (MobilePhoneModel);
CREATE INDEX refresh on hits (IsRefresh, DontCountHits);
CREATE INDEX resolutionwidth on hits (ResolutionWidth);
CREATE INDEX search on hits (SearchPhrase);
CREATE INDEX UserID on hits (UserID);

CREATE INDEX UserIDsearch on hits (UserID, SearchPhrase);
CREATE INDEX widcip on hits (WatchID, ClientIP);
CREATE INDEX mobileuser on hits (MobilePhoneModel,UserID);
CREATE INDEX regionuser on hits (RegionID,UserID);

CREATE INDEX mobile2 on hits (MobilePhoneModel) WHERE MobilePhoneModel <> ''::text;
CREATE INDEX search2 on hits (SearchPhrase) WHERE SearchPhrase <> ''::text;
