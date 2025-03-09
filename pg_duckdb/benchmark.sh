#!/bin/bash

set -ex

#sudo apt-get update
#sudo apt-get install -y docker.io
#sudo apt-get install -y postgresql-client

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz
sudo chmod 777 *

sudo docker run -d --name pgduck -p 5432:5432 -e POSTGRES_PASSWORD=duckdb -v ./:/tmp/files pgduckdb/pgduckdb:16-main

sudo docker exec -it pgduck bash -c "
    sed -i -e '
        s/shared_buffers = 128MB/shared_buffers = 8GB/;
        s/#max_parallel_workers = 8/max_parallel_workers = 16/;
        s/#max_parallel_workers_per_gather = 2/max_parallel_workers_per_gather = 8/;
        s/max_wal_size = 1GB/max_wal_size = 32GB/;
    ' /var/lib/postgresql/data/postgresql.conf
"

docker restart pgduck

sleep 5
docker exec -i pgduck psql -U postgres -c 'CREATE DATABASE test;'
docker exec -i pgduck psql -U postgres -d test -c 'CREATE EXTENSION IF NOT EXISTS pg_duckdb;'
docker exec -i pgduck psql -U postgres -d test -f /tmp/files/create.sql
time docker exec -i pgduck split /tmp/files/hits.tsv --verbose  -n r/$(( $(nproc)/2 )) --filter='psql -U postgres -d test -t -c "\\copy hits (WatchID, JavaEnable, Title, GoodEvent, EventTime, EventDate, CounterID, ClientIP, RegionID, UserID, CounterClass, OS, UserAgent, URL, Referer, IsRefresh, RefererCategoryID, RefererRegionID, URLCategoryID, URLRegionID, ResolutionWidth, ResolutionHeight, ResolutionDepth, FlashMajor, FlashMinor, FlashMinor2, NetMajor, NetMinor, UserAgentMajor, UserAgentMinor, CookieEnable, JavascriptEnable, IsMobile, MobilePhone, MobilePhoneModel, Params, IPNetworkID, TraficSourceID, SearchEngineID, SearchPhrase, AdvEngineID, IsArtifical, WindowClientWidth, WindowClientHeight, ClientTimeZone, ClientEventTime, SilverlightVersion1, SilverlightVersion2, SilverlightVersion3, SilverlightVersion4, PageCharset, CodeVersion, IsLink, IsDownload, IsNotBounce, FUniqID, OriginalURL, HID, IsOldCounter, IsEvent, IsParameter, DontCountHits, WithHash, HitColor, LocalEventTime, Age, Sex, Income, Interests, Robotness, RemoteIP, WindowName, OpenerName, HistoryLength, BrowserLanguage, BrowserCountry, SocialNetwork, SocialAction, HTTPError, SendTiming, DNSTiming, ConnectTiming, ResponseStartTiming, ResponseEndTiming, FetchTiming, SocialSourceNetworkID, SocialSourcePage, ParamPrice, ParamOrderID, ParamCurrency, ParamCurrencyID, OpenstatServiceName, OpenstatCampaignID, OpenstatAdID, OpenstatSourceID, UTMSource, UTMMedium, UTMCampaign, UTMContent, UTMTerm, FromTag, HasGCLID, RefererHash, URLHash, CLID) FROM STDIN"'
docker exec -i pgduck psql -U postgres -d test -f /tmp/files/index.sql
docker exec -i pgduck du -bcs /var/lib/postgresql/data

docker exec -i pgduck psql -U postgres -d test -c "ALTER DATABASE test SET duckdb.force_execution = true;"
./run.sh 2>&1 | tee log.txt

cat log.txt | grep -oP 'Time: \d+\.\d+ ms' | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
