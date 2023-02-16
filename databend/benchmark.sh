#!/bin/bash

mkdir databend && cd databend
curl -LJO 'https://github.com/datafuselabs/databend/releases/download/v0.9.39-nightly/databend-v0.9.39-nightly-x86_64-unknown-linux-musl.tar.gz'
tar xzvf 'databend-v0.9.39-nightly-x86_64-unknown-linux-musl.tar.gz'
 
cat > config.toml << CONF
[storage]
type = "fs"

[storage.fs]
data_path = "./_data"

[meta]
embedded_dir = "./.databend/meta_embedded"
CONF

# databend starts with embedded meta service
./bin/databend-query -c config.toml > query.log 2>&1 &

# Load the data
# Docs: https://databend.rs/doc/learn/analyze-hits-dataset-with-databend
curl 'http://default@localhost:8124/' --data-binary @create.sql

wget --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
gzip -d hits.tsv.gz

time curl -XPUT 'http://root:@127.0.0.1:8000/v1/streaming_load' -H 'insert_sql: insert into hits FILE_FORMAT = (type = TSV)' -F 'upload=@"./hits.tsv"'

## in c6a.4xlarge it's ~360s, in c6a.metal it's ~70s
# {"id":"702fac1f-e326-4a87-a945-bc2a0d627531","state":"SUCCESS","stats":{"rows":99997497,"bytes":74807831229},"error":null,"files":["hits.tsv"]}
# real    5m59.218s
# user    0m1.805s
# sys     0m33.284s

## check data is correct
curl 'http://default@localhost:8124/' --data-binary "select count() from hits"

# [ec2-user@ip-172-31-16-92 databend]$ du -bcs _data
# 20922561953     _data
# 20922561953     total

./run.sh 2>&1 | tee log.txt
