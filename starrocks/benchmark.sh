#!/bin/bash

# This benchmark should run on Amazon Linux

set -e

VERSION=4.0.2-ubuntu-$(dpkg --print-architecture)
# Install
wget --continue --progress=dot:giga https://releases.starrocks.io/starrocks/StarRocks-$VERSION.tar.gz -O StarRocks-$VERSION.tar.gz
tar zxvf StarRocks-${VERSION}.tar.gz

cd StarRocks-${VERSION}/

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jre mariadb-client
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)
export PATH=$JAVA_HOME/bin:$PATH

# Create directory for FE and BE
IPADDR=`hostname -i`
export STARROCKS_HOME=`pwd`
mkdir -p meta storage

# Start Frontend
printf "\nmeta_dir = ${STARROCKS_HOME}/meta \n" >> fe/conf/fe.conf
fe/bin/start_fe.sh --daemon

# Start Backend
printf "\nstorage_root_path = ${STARROCKS_HOME}/storage\n" >> be/conf/be.conf
be/bin/start_be.sh --daemon

# Setup cluster
# wait some seconds util fe can serve
sleep 30
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '${IPADDR}:9050' "
# wait some seconds util be joins
sleep 30

# Prepare Data
cd ../
sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

# Create Table
mysql -h 127.0.0.1 -P9030 -uroot -e "CREATE DATABASE hits"
mysql -h 127.0.0.1 -P9030 -uroot hits < create.sql

# Load Data
START=$(date +%s)
echo "Start to load data..."
curl --location-trusted \
    -u root: \
    -T "hits.tsv" \
    -H "label:hits_tsv_${START}" \
    -H "timeout:1000" \ # see https://github.com/ClickHouse/ClickBench/pull/740
    -H "columns: WatchID,JavaEnable,Title,GoodEvent,EventTime,EventDate,CounterID,ClientIP,RegionID,UserID,CounterClass,OS,UserAgent,URL,Referer,IsRefresh,RefererCategoryID,RefererRegionID,URLCategoryID,URLRegionID,ResolutionWidth,ResolutionHeight,ResolutionDepth,FlashMajor,FlashMinor,FlashMinor2,NetMajor,NetMinor,UserAgentMajor,UserAgentMinor,CookieEnable,JavascriptEnable,IsMobile,MobilePhone,MobilePhoneModel,Params,IPNetworkID,TraficSourceID,SearchEngineID,SearchPhrase,AdvEngineID,IsArtifical,WindowClientWidth,WindowClientHeight,ClientTimeZone,ClientEventTime,SilverlightVersion1,SilverlightVersion2,SilverlightVersion3,SilverlightVersion4,PageCharset,CodeVersion,IsLink,IsDownload,IsNotBounce,FUniqID,OriginalURL,HID,IsOldCounter,IsEvent,IsParameter,DontCountHits,WithHash,HitColor,LocalEventTime,Age,Sex,Income,Interests,Robotness,RemoteIP,WindowName,OpenerName,HistoryLength,BrowserLanguage,BrowserCountry,SocialNetwork,SocialAction,HTTPError,SendTiming,DNSTiming,ConnectTiming,ResponseStartTiming,ResponseEndTiming,FetchTiming,SocialSourceNetworkID,SocialSourcePage,ParamPrice,ParamOrderID,ParamCurrency,ParamCurrencyID,OpenstatServiceName,OpenstatCampaignID,OpenstatAdID,OpenstatSourceID,UTMSource,UTMMedium,UTMCampaign,UTMContent,UTMTerm,FromTag,HasGCLID,RefererHash,URLHash,CLID" \
    http://localhost:8030/api/hits/hits/_stream_load
END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load time: $LOADTIME"

# Dataset contains about 40GB of data when the import is just completed.
# This is because the trashed data generated during the compaction process.
# After about tens of minutes, when the gc is completed, the system includes about 16.5GB of data.
echo -n "Data size: "
du -bcs StarRocks-${VERSION}/storage/ | grep total
# Dataset contains 99997497 rows
mysql -h 127.0.0.1 -P9030 -uroot hits -e "SELECT count(*) FROM hits"

./run.sh 2>&1 | tee -a log.txt

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
