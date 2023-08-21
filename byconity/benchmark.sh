#!/bin/bash

docker-compose up -d
sleep 5

hdfs/create_users.sh

function byconity()
{
    docker-compose exec -T server clickhouse-client --port 52145 "$@"
}
export -f byconity

byconity --time -n < create.sql
wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -fkd hits.tsv.gz
byconity --database bench --query "INSERT INTO hits FORMAT TSV" < hits.tsv

# NOTE: sometimes may hung due to docker-compose, using docker directly may help
./run.sh

byconity --enable_multiple_tables_for_cnch_parts=1 --query "SELECT sum(bytes_on_disk) FROM system.cnch_parts WHERE table = 'hits' AND database = 'bench'"

docker-compose down --volumes
