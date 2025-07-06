#!/bin/bash

CRDBVERSION=25.1.6
CRDBDATADIR=/var/lib/cockroach-data

sudo apt-get update -y
# Includes unbuffer utility program
sudo apt-get install -y expect-dev

wget --continue --progress=dot:giga https://binaries.cockroachdb.com/cockroach-v$CRDBVERSION.linux-amd64.tgz
tar -xvzf cockroach-v$CRDBVERSION.linux-amd64.tgz
sudo cp -r cockroach-v$CRDBVERSION.linux-amd64/* /usr/local/bin/
# Build Tag:        v25.1.6
cockroach version | grep "^Build Tag"
sudo mkdir -p $CRDBDATADIR
# Increase cache size to 25% for better read performance
# For details see https://www.cockroachlabs.com/docs/v25.1/recommended-production-settings#cache-and-sql-memory-size
sudo cockroach start-single-node --insecure --listen-addr=localhost --background --store=$CRDBDATADIR --cache=.25 --pid-file=crdb.pid

wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz' -O /tmp/hits.csv.gz
# Make data file available in "extern" directory, so it can be loaded via nodelocal
sudo mkdir -p $CRDBDATADIR/extern
gzip -d -c /tmp/hits.csv.gz | sudo tee $CRDBDATADIR/extern/hits.csv > /dev/null

# Deactivate query plan cache
# For details see https://www.cockroachlabs.com/docs/v25.1/cost-based-optimizer#query-plan-cache
cockroach sql --insecure --host=localhost --execute='SET CLUSTER SETTING sql.query_cache.enabled = false;'

cockroach sql --insecure --host=localhost --execute='CREATE DATABASE test;'
cockroach sql --insecure --host=localhost --database=test --file='create.sql'
echo -n "Load time: "
command time -f '%e' cockroach sql --insecure --host=localhost --database=test --execute="IMPORT INTO hits(WatchID, JavaEnable, Title, GoodEvent, EventTime, EventDate, CounterID, ClientIP, RegionID, UserID, CounterClass, OS, UserAgent, URL, Referer, IsRefresh, RefererCategoryID, RefererRegionID, URLCategoryID, URLRegionID, ResolutionWidth, ResolutionHeight, ResolutionDepth, FlashMajor, FlashMinor, FlashMinor2, NetMajor, NetMinor, UserAgentMajor, UserAgentMinor, CookieEnable, JavascriptEnable, IsMobile, MobilePhone, MobilePhoneModel, Params, IPNetworkID, TraficSourceID, SearchEngineID, SearchPhrase, AdvEngineID, IsArtifical, WindowClientWidth, WindowClientHeight, ClientTimeZone, ClientEventTime, SilverlightVersion1, SilverlightVersion2, SilverlightVersion3, SilverlightVersion4, PageCharset, CodeVersion, IsLink, IsDownload, IsNotBounce, FUniqID, OriginalURL, HID, IsOldCounter, IsEvent, IsParameter, DontCountHits, WithHash, HitColor, LocalEventTime, Age, Sex, Income, Interests, Robotness, RemoteIP, WindowName, OpenerName, HistoryLength, BrowserLanguage, BrowserCountry, SocialNetwork, SocialAction, HTTPError, SendTiming, DNSTiming, ConnectTiming, ResponseStartTiming, ResponseEndTiming, FetchTiming, SocialSourceNetworkID, SocialSourcePage, ParamPrice, ParamOrderID, ParamCurrency, ParamCurrencyID, OpenstatServiceName, OpenstatCampaignID, OpenstatAdID, OpenstatSourceID, UTMSource, UTMMedium, UTMCampaign, UTMContent, UTMTerm, FromTag, HasGCLID, RefererHash, URLHash, CLID) CSV DATA ('nodelocal://1/hits.csv');"

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
cockroach sql --insecure --host=localhost --database=test --execute="SELECT SUM(range_size) FROM [SHOW RANGES FROM TABLE hits WITH DETAILS];"

# Values might be given in ms or s, depending on their magnitude
grep -oP 'Time: \K[\d.]+s|Time: \K\d+ms' log.txt |
  sed -E 's/([0-9]+(\.[0-9]+)?)s/\1/; s/([0-9]+)ms/\1\/1000/' |
  awk '{if ($0 ~ /\//) {print $1/1000} else {print $0}}' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
