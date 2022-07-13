#!/bin/bash

mkdir databend && cd databend
curl -LJO 'https://github.com/datafuselabs/databend/releases/download/v0.7.127-nightly/databend-v0.7.127-nightly-x86_64-unknown-linux-musl.tar.gz'
tar xzvf 'databend-v0.7.127-nightly-x86_64-unknown-linux-musl.tar.gz'

echo 'dir = "metadata/_logs"
admin_api_address = "127.0.0.1:8101"
grpc_api_address = "127.0.0.1:9101"

[raft_config]
id = 1
single = true
raft_dir = "metadata/datas"' > databend-meta.toml

./bin/databend-meta -c ./databend-meta.toml > meta.log 2>&1 &
curl -I 'http://127.0.0.1:8101/v1/health'

echo '[log]
level = "INFO"
dir = "benddata/_logs"

[query]
# For admin RESET API.
admin_api_address = "127.0.0.1:8001"

# Metrics.
metric_api_address = "127.0.0.1:7071"

# Cluster flight RPC.
flight_api_address = "127.0.0.1:9091"

# Query MySQL Handler.
mysql_handler_host = "127.0.0.1"
mysql_handler_port = 3307

# Query ClickHouse Handler.
clickhouse_handler_host = "127.0.0.1"
clickhouse_handler_port = 9001

# Query ClickHouse HTTP Handler.
clickhouse_http_handler_host = "127.0.0.1"
clickhouse_http_handler_port = 8125

# Query HTTP Handler.
http_handler_host = "127.0.0.1"
http_handler_port = 8081

tenant_id = "tenant1"
cluster_id = "cluster1"

[meta]
# databend-meta grpc api address.
address = "127.0.0.1:9101"
username = "root"
password = "root"

[storage]
# fs|s3
type = "fs"

[storage.fs]
data_path = "benddata/datas"' > databend-query.toml

./bin/databend-query -c ./databend-query.toml > query.log 2>&1 &

curl https://clickhouse.com/ | sh
sudo ./clickhouse install

# Load the data
# Docs: https://databend.rs/doc/learn/analyze-hits-dataset-with-databend

curl 'http://default@localhost:8124/' --data-binary @create.sql

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

# Note:
# clickhouse-client --time --query "INSERT INTO hits FORMAT TSV" < hits.tsv
# can work but it's a bit slower than streaming load

time curl -XPUT 'http://root:@127.0.0.1:8000/v1/streaming_load' -H 'insert_sql: insert into hits format TSV' -H 'skip_header: 0' -H 'field_delimiter: \t' -H 'record_delimiter: \n' -F 'upload=@"./hits.tsv"'

# {"id":"3cd85230-02ea-427b-9af3-43bfe4ea54b5","state":"SUCCESS","stats":{"rows":99997497,"bytes":81443407622},"error":null}
# real    7m15.312s

wc -l hits.tsv                                  1
# 99997497 hits.tsv

du -bcs _data
# 15380105715

./run.sh 2>&1 | tee log.txt
