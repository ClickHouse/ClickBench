#!/bin/bash -e

# Load the data

# export FQDN=...
# export USER=...
# export PASSWORD=...
# export AK=...
# export SK=...
# export STORAGE=...
# export REPLICAS=...
# export CCU=...
# export OSS_URL=..., eg. "https://clickhouse-test-clickbench-hangzhou.oss-cn-hangzhou-internal.aliyuncs.com/clickbench/hits_parquets/hits_{0..99}.parquet"
 
export CATEGORY="ent"
 
MAX_INSERT_THREADS=$(clickhouse-client --host "$FDQN" --user "$USER" --password "$PASSWORD" --query "SELECT intDiv(getSetting('max_threads'), 4)")

load_time=$(clickhouse-client --host "$FDQN" --user "$USER" --password "$PASSWORD" --enable-parallel-replicas 1 --max-insert-threads $MAX_INSERT_THREADS --query="INSERT INTO hits SELECT * FROM s3Cluster('default', '$OSS_URL', '$AK', '$SK', 'parquet');" --time 2>&1)


result=$(./run.sh)

data_size=$(clickhouse-client --host "$FDQN" --user "$USER" --password "$PASSWORD" --query="SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'")

echo '
{
    "system": "ClickHouse ☁️ (alicloud-'$STORAGE')",
    "date": "'$(date +%F)'",
    "machine": "AliCloud: '$CCU'CCU",
    "cluster_size": '$REPLICAS',

    "proprietary": "yes",
    "hardware": "cpu",
    "tuned": "no",
    "comment": "",

    "tags": ["C++", "column-oriented", "ClickHouse derivative", "managed", "alicloud"],

    "load_time": '$load_time',
    "data_size": '$data_size',

    "result": [
      '$(echo "$result" | sed '$ s/.$//')'
    ]
}
' > "results/alicloud-$CATEGORY-$REPLICAS-$STORAGE-$CCU-$REPLICAS.json"
