#!/bin/bash

sudo apt-get update -y
sudo apt-get install -y docker.io

sudo docker run -p 5433:5433 -p 5444:5444 --volume $(pwd):/workdir --mount type=volume,source=vertica-data,target=/data --name vertica_ce vertica/vertica-ce

sudo docker exec vertica_ce /opt/vertica/bin/vsql -U dbadmin -c "$(cat create.sql)"

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.tsv.gz'
pigz -d -f hits.tsv.gz

echo -n "Load time: "
command time -f '%e' sudo docker exec vertica_ce /opt/vertica/bin/vsql -U dbadmin -c "COPY hits FROM LOCAL '/workdir/hits.tsv' DELIMITER E'\\t' NULL E'\\001' DIRECT"

echo -n "Data size: "
sudo docker exec vertica_ce du -bcs /data/vertica/VMart | grep total

./run.sh 2>&1 | tee log.txt

# If you run the script on your own, you may get numbers like this:
# 200m00.000s
# 25000000000

# Note: the real numbers cannot be published.

grep -F 'All rows formatted' logs.txt | sed -r -e 's/^.* ([0-9.]+) ms$/\1/' |
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1 / 1000; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
