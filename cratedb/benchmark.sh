#!/bin/bash

# Tuned execution if "tuned" is passed, default mode otherwise
MODE=$1

if [[ $MODE == "tuned" ]]; then
  CREATE_FILE="create-tuned.sql"
  EMPTY_STRING_AS_NULL=TRUE
else
  CREATE_FILE="create.sql"
  EMPTY_STRING_AS_NULL=FALSE
fi;

# Install prerequisites.
sudo apt update
sudo apt install -y apt-transport-https apt-utils curl gnupg lsb-release

# Import the public GPG key for verifying the package signatures.
curl -sS https://cdn.crate.io/downloads/debian/DEB-GPG-KEY-crate | \
    sudo tee /etc/apt/trusted.gpg.d/cratedb.asc

# Add CrateDB repository to Apt
echo "deb https://cdn.crate.io/downloads/debian/testing/ default main" | \
    sudo tee /etc/apt/sources.list.d/crate-stable.list

sudo apt-get update
sudo apt-get install -y postgresql-client crate

sudo systemctl start crate

while true
do
  psql -U crate -h localhost --no-password -t -c 'SELECT 1' && break
  sleep 1
done

wget --no-verbose --continue 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz' -O /tmp/hits.tsv.gz
gzip -d /tmp/hits.tsv.gz
chmod 444 /tmp/hits.tsv

psql -U crate -h localhost --no-password -t < $CREATE_FILE

psql -U crate -h localhost --no-password -t -c '\timing' -c "
  COPY hits
  FROM 'file:///tmp/hits.tsv'
  WITH
  (
    "delimiter"=e'\t',
    "format"='csv',
    "header"=false,
    "empty_string_as_null"=${EMPTY_STRING_AS_NULL}
  )
  RETURN SUMMARY;"

# One record did not load:
# 99997496
# {"Missing closing quote for value\n at [Source: UNKNOWN; line: 1, column: 1069]":{"count":1,"line_numbers":[93557187]}}
# Time: 10687056.069 ms (02:58:07.056)

if [[ $MODE == "tuned" ]]; then
  psql -U crate -h localhost --no-password -t -c "REFRESH TABLE hits; OPTIMIZE TABLE hits;"
fi;

# Some queries don't fit into the available heap space and raise an CircuitBreakingException
./run.sh "$MODE" 2>&1 | tee log.txt

# Look up shard sizes from system tables. Only consider primary shards in case of multi-node setups with replication.
psql -U crate -h localhost --no-password -t -c "SELECT SUM(size) FROM sys.shards WHERE table_name = 'hits' AND primary = TRUE;"

grep -oP 'Time: \d+\.\d+ ms|ERROR' < log.txt | sed -r -e 's/Time: ([0-9]+\.[0-9]+) ms/\1/' |
  awk '{ if ($1 == "ERROR") { skip = 1 } else { if (i % 3 == 0) { printf "[" }; printf skip ? "null" : ($1 / 1000); if (i % 3 != 2) { printf "," } else { print "]," }; ++i; skip = 0; } }'
