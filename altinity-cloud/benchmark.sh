#!/bin/bash -e

#set -x
# Go to https://clickhouse.cloud/ and create a service.
# To get results for various scale, go to "Actions / Advanced Scaling" and turn the slider of the minimum scale to the right.
# The number of threads is "SELECT value FROM system.settings WHERE name = 'max_threads'".

# Load the data

# export FQDN=...
# export PASSWORD=...

set -o allexport
source ../.env
set +o allexport

SQL_QUERY_CREATE=$(cat create.sql)

CH_CLIENT="clickhouse client \
            --config-file=$PATH2XML \
            --host "${FQDN:=localhost}" \
            --port 9440 \
            --user=$USER \
            --password "${PASSWORD:=}" \
            ${PASSWORD:+--secure} \
            --time \
            --progress 0"

RESULT_DATE=$($CH_CLIENT --query="SELECT today();")
echo "TODAY=$RESULT_DATE"

#RESULT_CREATE=$($CH_CLIENT --query="$SQL_QUERY_CREATE")
RESULT_CREATE="0.310"

SQL_RESULT="INSERT INTO hits SELECT * FROM url('https://clickhouse-public-datasets.s3.amazonaws.com/hits_compatible/hits.tsv.gz')"
RESULT_TIME_TO_LOAD=$($CH_CLIENT --query="$SQL_RESULT")
#RESULT_TIME_TO_LOAD="293379"

# 343.455

# Run the queries

./run.sh

SQL_RESULT="SELECT total_bytes FROM system.tables WHERE name = 'hits' AND database = 'default'"

RESULT_SIZE=$($CH_CLIENT --query="$SQL_RESULT")
#echo $RESULT_SIZE



# JSON file
OUTPUT_FILE="results/c6a.4xlarge.altinityantalya.json"

cat > "$OUTPUT_FILE" <<EOF
{
  "system": "Altinity-cloud-aws",
  "date": "$RESULT_DATE",
  "machine": "c6a.4xlarge",
  "cluster_size": 1,
  "comment": "c6a.4xlarge, 500gb gp2, aws, 25.3.3.20186.altinityantalya",
  "tags": ["C++", "ClickHouse", "column-oriented", "Altinity"],
  "load_time": $RESULT_TIME_TO_LOAD,
  "data_size": $RESULT_SIZE,
  "result": [ $(cat result.csv | sed '$s/,\s*$//')  ]
}
EOF