#!/bin/bash

# Go to https://cloud.celerdata.com/ and create a service.
# Choose m6i.2xlarge as FE, c6a.metal as BE
# Ensure the test host in same region of new CelerData cluster

# This benchmark should run on Amazon Linux

# Prepare Data
cd ../
wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

# Create Table
mysql -h $Endpoint -P9030 -u$user -p$password -e "CREATE DATABASE hits"
mysql -h $Endpoint -P9030 -u$user -p$password -D hits < create.sql

# Load Data
START=$(date +%s)
echo "Start to load data..."
curl --location-trusted \
    -u root: \
    -T "hits.tsv" \
    -H "label:hits_tsv_${START}" \
    -H "columns: WatchID,JavaEnable,Title,GoodEvent,EventTime,EventDate,CounterID,ClientIP,RegionID,UserID,CounterClass,OS,UserAgent,URL,Referer,IsRefresh,RefererCategoryID,RefererRegionID,URLCategoryID,URLRegionID,ResolutionWidth,ResolutionHeight,ResolutionDepth,FlashMajor,FlashMinor,FlashMinor2,NetMajor,NetMinor,UserAgentMajor,UserAgentMinor,CookieEnable,JavascriptEnable,IsMobile,MobilePhone,MobilePhoneModel,Params,IPNetworkID,TraficSourceID,SearchEngineID,SearchPhrase,AdvEngineID,IsArtifical,WindowClientWidth,WindowClientHeight,ClientTimeZone,ClientEventTime,SilverlightVersion1,SilverlightVersion2,SilverlightVersion3,SilverlightVersion4,PageCharset,CodeVersion,IsLink,IsDownload,IsNotBounce,FUniqID,OriginalURL,HID,IsOldCounter,IsEvent,IsParameter,DontCountHits,WithHash,HitColor,LocalEventTime,Age,Sex,Income,Interests,Robotness,RemoteIP,WindowName,OpenerName,HistoryLength,BrowserLanguage,BrowserCountry,SocialNetwork,SocialAction,HTTPError,SendTiming,DNSTiming,ConnectTiming,ResponseStartTiming,ResponseEndTiming,FetchTiming,SocialSourceNetworkID,SocialSourcePage,ParamPrice,ParamOrderID,ParamCurrency,ParamCurrencyID,OpenstatServiceName,OpenstatCampaignID,OpenstatAdID,OpenstatSourceID,UTMSource,UTMMedium,UTMCampaign,UTMContent,UTMTerm,FromTag,HasGCLID,RefererHash,URLHash,CLID" \
    http://$Endpoint/api/hits/hits/_stream_load
END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load data costs $LOADTIME seconds"

# Dataset contains about 40GB of data when the import is just completed.
# This is because the trashed data generated during the compaction process.
# After about tens of minutes, when the gc is completed, the system includes about 16.7GB of data.
# Dataset contains 99997497 rows
mysql -vvv -h $Endpoint -uadmin -P9030 -D hits -e "show data" | \
	grep "hits" | \
	perl -ne '/\|\s*hits\s*\|\s*(\d+\.?\d*) GB\s*\|/; printf "%.0f\n", $1 * 2**30'

# Run queries
./run.sh 2>&1 | tee run.log

sed -r -e 's/query[0-9]+,/[/; s/$/],/' run.log
