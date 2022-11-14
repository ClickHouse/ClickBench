#!/bin/bash

mkdir databend && cd databend
curl -LJO 'https://github.com/datafuselabs/databend/releases/download/v0.7.127-nightly/databend-v0.7.127-nightly-x86_64-unknown-linux-musl.tar.gz'
tar xzvf 'databend-v0.7.127-nightly-x86_64-unknown-linux-musl.tar.gz'
 
# databend starts with embedded meta service (meta stored in `.databend` directory, data in `_data` directory)
./bin/databend-query > query.log 2>&1 &

# Load the data
# Docs: https://databend.rs/doc/learn/analyze-hits-dataset-with-databend

curl 'http://default@localhost:8124/' --data-binary @create.sql

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

time curl -XPUT 'http://root:@127.0.0.1:8000/v1/streaming_load' -H 'insert_sql: insert into hits format TSV' -H 'skip_header: 0' -H 'field_delimiter: \t' -H 'record_delimiter: \n' -F 'upload=@"./hits.tsv"'

# {"id":"b9e20026-7eb2-4f09-a6b3-3ab79c4cb1fd","state":"SUCCESS","stats":{"rows":99997497,"bytes":81443407174},"error":null}
# real    8m17.103s

wc -l hits.tsv                                  1
# 99997497 hits.tsv

du -bcs _data
# 15376458490

./run.sh 2>&1 | tee log.txt
