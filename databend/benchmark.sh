#!/bin/bash

mkdir databend && cd databend
curl -LJO 'https://github.com/datafuselabs/databend/releases/download/v0.8.111-nightly/databend-v0.8.111-nightly-x86_64-unknown-linux-musl.tar.gz'
tar xzvf 'databend-v0.8.111-nightly-x86_64-unknown-linux-musl.tar.gz'
 
# databend starts with embedded meta service (meta stored in `.databend` directory, data in `_data` directory)
./bin/databend-query --table-cache-enabled > query.log 2>&1 &

# Load the data
# Docs: https://databend.rs/doc/learn/analyze-hits-dataset-with-databend

curl 'http://default@localhost:8124/' --data-binary @create.sql

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

time curl -XPUT 'http://root:@127.0.0.1:8000/v1/streaming_load' -H 'insert_sql: insert into hits format TSV' -F 'upload=@"./hits.tsv"'

# {"id":"5f8ea959-48ff-46df-af75-d9519fc3bff1","state":"SUCCESS","stats":{"rows":99997497,"bytes":74807831229},"error":null,"files":["hits.tsv"]}
# real    7m22.807s
# user    0m2.165s
# sys     0m42.153s

du -bcs _data
# 16075899488

./run.sh 2>&1 | tee log.txt
