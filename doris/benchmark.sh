#!/bin/bash
set -e

# This benchmark should run on Ubuntu 20.04

# Install
ROOT=$(pwd)

if [[ -n "$1" ]]; then
    url="$1"
else
    url='https://apache-doris-releases.oss-accelerate.aliyuncs.com/apache-doris-4.1.0-rc01-bin-x64.tar.gz'
fi
# Download
file_name="$(basename ${url})"
if [[ "$url" == "http"* ]]; then
    if [[ ! -f $file_name ]]; then
        wget --continue --progress=dot:giga ${url}
    else
        echo "$file_name already exists, no need to download."
    fi
fi
dir_name="${file_name/.tar.gz/}"

# Try to stop Doris and remove it first if execute this script multiple times
set +e
"$dir_name"/"$dir_name"/fe/bin/stop_fe.sh
"$dir_name"/"$dir_name"/be/bin/stop_be.sh
rm -rf "$dir_name"
set -e

# Uncompress
mkdir "$dir_name"
tar zxf "$file_name" -C "$dir_name"
DORIS_HOME="$ROOT/$dir_name/$dir_name"
export DORIS_HOME

# Install dependencies
sudo apt-get update -y
sudo apt-get install -y openjdk-17-jdk mysql-client
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)/"
export PATH=$JAVA_HOME/bin:$PATH

sudo systemctl disable unattended-upgrades
sudo systemctl stop unattended-upgrades

"$DORIS_HOME"/fe/bin/start_fe.sh --daemon

# Start Backend
sudo sysctl -w vm.max_map_count=2000000
ulimit -n 65535
# Disable internal caches so that the cold run (1st of 3 tries) is actually cold.
# Without this, the BE process keeps decoded data in its own in-memory page cache
# (`storage_page_cache`, default ~20% of RAM) and segment cache, which `drop_caches`
# does not clear, so first-run timings reflect a warm cache and underreport
# cold-run latency.
printf "\ndisable_storage_page_cache = true\n" >> "$DORIS_HOME"/be/conf/be.conf
printf "\nsegment_cache_capacity = 0\n" >> "$DORIS_HOME"/be/conf/be.conf
"$DORIS_HOME"/be/bin/start_be.sh --daemon

# Wait for Frontend ready
for _ in {1..300}
do
    fe_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show frontends' | cut -f16 | sed -n '2,$p')
    if [[ -n "${fe_version}" ]] && [[ "${fe_version}" != "NULL" ]]; then
        echo "Frontend version: ${fe_version}"
        break
    else
        echo 'Wait for Frontend ready ...'
        sleep 2
    fi
done

# Setup cluster, add Backend to cluster
mysql -h 127.0.0.1 -P9030 -uroot -e "ALTER SYSTEM ADD BACKEND '127.0.0.1:9050' "

# Wait for Backend ready
for _ in {1..300}
do
    be_version=$(mysql -h127.0.0.1 -P9030 -uroot -e 'show backends' | cut -f22 | sed -n '2,$p')
    if [[ -n "${be_version}" ]]; then
        echo "Backend version: ${be_version}"
        break
    else
        echo 'Wait for Backend ready ...'
        sleep 2
    fi
done

echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

# Create Database and table
mysql -h 127.0.0.1 -P9030 -uroot -e "CREATE DATABASE hits"
sleep 5
mysql -h 127.0.0.1 -P9030 -uroot hits <"$ROOT"/create.sql

# Download data
BE_DATA_DIR="$DORIS_HOME/be/"

"$ROOT"/../download-hits-parquet-partitioned "$BE_DATA_DIR/user_files_secure"

BE_ID=$(mysql -h127.0.0.1 -P9030 -uroot -N -e 'show backends' | awk '{print $1}' | head -1)

CORES=$(nproc)
PARALLEL_NUM=$((CORES / 4))
if [ "$PARALLEL_NUM" -lt 1 ]; then
    echo "Computed parallel_pipeline_task_num ($PARALLEL_NUM) is less than 1 based on $CORES cores; clamping to 1."
    PARALLEL_NUM=1
fi
echo "Setting parallel_pipeline_task_num to $PARALLEL_NUM (cpu cores: $CORES, computed as CORES/4 with min 1)"

echo "start loading hits.parquet using TVF, estimated to take about 3 minutes ..."
START=$(date +%s)
mysql -h 127.0.0.1 -P9030 -uroot hits -e "SET parallel_pipeline_task_num = $PARALLEL_NUM;\
INSERT INTO hits SELECT
    CounterID,
    DATE_ADD('1970-01-01', INTERVAL EventDate DAY) AS EventDate,
    UserID,
    FROM_UNIXTIME(EventTime) AS EventTime,
    WatchID,
    JavaEnable,
    Title,
    GoodEvent,
    ClientIP,
    RegionID,
    CounterClass,
    OS,
    UserAgent,
    URL,
    Referer,
    IsRefresh,
    RefererCategoryID,
    RefererRegionID,
    URLCategoryID,
    URLRegionID,
    ResolutionWidth,
    ResolutionHeight,
    ResolutionDepth,
    FlashMajor,
    FlashMinor,
    FlashMinor2,
    NetMajor,
    NetMinor,
    UserAgentMajor,
    UserAgentMinor,
    CookieEnable,
    JavascriptEnable,
    IsMobile,
    MobilePhone,
    MobilePhoneModel,
    Params,
    IPNetworkID,
    TraficSourceID,
    SearchEngineID,
    SearchPhrase,
    AdvEngineID,
    IsArtifical,
    WindowClientWidth,
    WindowClientHeight,
    ClientTimeZone,
    FROM_UNIXTIME(ClientEventTime) AS ClientEventTime,
    SilverlightVersion1,
    SilverlightVersion2,
    SilverlightVersion3,
    SilverlightVersion4,
    PageCharset,
    CodeVersion,
    IsLink,
    IsDownload,
    IsNotBounce,
    FUniqID,
    OriginalURL,
    HID,
    IsOldCounter,
    IsEvent,
    IsParameter,
    DontCountHits,
    WithHash,
    HitColor,
    FROM_UNIXTIME(LocalEventTime) AS LocalEventTime,
    Age,
    Sex,
    Income,
    Interests,
    Robotness,
    RemoteIP,
    WindowName,
    OpenerName,
    HistoryLength,
    BrowserLanguage,
    BrowserCountry,
    SocialNetwork,
    SocialAction,
    HTTPError,
    SendTiming,
    DNSTiming,
    ConnectTiming,
    ResponseStartTiming,
    ResponseEndTiming,
    FetchTiming,
    SocialSourceNetworkID,
    SocialSourcePage,
    ParamPrice,
    ParamOrderID,
    ParamCurrency,
    ParamCurrencyID,
    OpenstatServiceName,
    OpenstatCampaignID,
    OpenstatAdID,
    OpenstatSourceID,
    UTMSource,
    UTMMedium,
    UTMCampaign,
    UTMContent,
    UTMTerm,
    FromTag,
    HasGCLID,
    RefererHash,
    URLHash,
    CLID
FROM local(
    \"file_path\" = \"user_files_secure/hits_*.parquet\",
    \"backend_id\" = \"$BE_ID\",
    \"format\" = \"parquet\"
)
"
END=$(date +%s)
LOADTIME=$(echo "$END - $START" | bc)
echo "Load time: $LOADTIME"
echo "$LOADTIME" > loadtime


du -bs "$DORIS_HOME"/be/storage/ | cut -f1 | tee storage_size
echo "Data size: $(cat storage_size)"

mysql -h 127.0.0.1 -P9030 -uroot hits -e "set global enable_sql_cache = false"
# Dataset contains 99997497 rows, storage size is about 13319588503 bytes
mysql -h 127.0.0.1 -P9030 -uroot hits -e "SELECT count(*) FROM hits"

# Run queries
TRIES=3
while read -r query; do
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null

    for i in $(seq 1 $TRIES); do
        mysql -vvv -h127.1 -P9030 -uroot hits -e "${query}" 2>&1 | tee -a log.txt
    done
done <queries.sql

cat log.txt |
  grep -P 'rows? in set|Empty set|^ERROR' |
  sed -r -e 's/^ERROR.*$/null/; s/^.*?\((([0-9.]+) min )?([0-9.]+) sec\).*?$/\2 \3/' |
  awk '{ if ($2 != "") { print $1 * 60 + $2 } else { print $1 } }' |
  awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
