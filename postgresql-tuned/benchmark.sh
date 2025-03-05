#!/bin/bash

sudo apt-get update
sudo apt-get install -y postgresql-common postgresql-14

sudo sed -i -e '
    s/shared_buffers = 128MB/shared_buffers = 8GB/;
    s/#max_parallel_workers = 8/max_parallel_workers=16/;
    s/#max_parallel_workers_per_gather = 2/max_parallel_workers_per_gather = 8/;
    s/max_wal_size = 1GB/max_wal_size=32GB/;
' /etc/postgresql/14/main/postgresql.conf

sudo systemctl restart postgresql@14-main


sudo mkdir /benchmark
sudo chmod 777 /benchmark
cd /benchmark

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
chmod 666 hits.tsv

sudo -u postgres psql -t -c 'CREATE DATABASE test'
sudo -u postgres psql test -t < create.sql

# Using COPY with explicit column mapping to ensure correct alignment.
time split hits.tsv --verbose -n r/$(( $(nproc)/2 )) --filter='sudo -u postgres psql test -t -c "\\copy hits (WatchID, JavaEnable, Title, GoodEvent, EventTime, EventDate, CounterID, ClientIP, RegionID, UserID, CounterClass, OS, UserAgent, URL, Referer, IsRefresh, RefererCategoryID, RefererRegionID, URLCategoryID, URLRegionID, ResolutionWidth, ResolutionHeight, ResolutionDepth, FlashMajor, FlashMinor, FlashMinor2, NetMajor, NetMinor, UserAgentMajor, UserAgentMinor, CookieEnable, JavascriptEnable, IsMobile, MobilePhone, MobilePhoneModel, Params, IPNetworkID, TraficSourceID, SearchEngineID, SearchPhrase, AdvEngineID, IsArtifical, WindowClientWidth, WindowClientHeight, ClientTimeZone, ClientEventTime, SilverlightVersion1, SilverlightVersion2, SilverlightVersion3, SilverlightVersion4, PageCharset, CodeVersion, IsLink, IsDownload, IsNotBounce, FUniqID, OriginalURL, HID, IsOldCounter, IsEvent, IsParameter, DontCountHits, WithHash, HitColor, LocalEventTime, Age, Sex, Income, Interests, Robotness, RemoteIP, WindowName, OpenerName, HistoryLength, BrowserLanguage, BrowserCountry, SocialNetwork, SocialAction, HTTPError, SendTiming, DNSTiming, ConnectTiming, ResponseStartTiming, ResponseEndTiming, FetchTiming, SocialSourceNetworkID, SocialSourcePage, ParamPrice, ParamOrderID, ParamCurrency, ParamCurrencyID, OpenstatServiceName, OpenstatCampaignID, OpenstatAdID, OpenstatSourceID, UTMSource, UTMMedium, UTMCampaign, UTMContent, UTMTerm, FromTag, HasGCLID, RefererHash, URLHash, CLID) FROM STDIN"'

sudo -u postgres psql test -t -c 'CREATE EXTENSION pg_trgm;'
time sudo -u postgres psql test -t < index.sql

time sudo -u postgres psql test -t -c 'VACUUM ANALYZE hits'

# COPY 99997497
# Time: 2341543.463 ms (39:01.543)

./run.sh 2>&1 | tee log.txt

sudo du -bcs /var/lib/postgresql/14/main/

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
