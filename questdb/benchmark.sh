#!/bin/bash

# Install

qdb_version="9.2.2"
if [[ $(arch) == "aarch64" ]] || [[ $(arch) == "arm"* ]]; then
  # ARM uses no-JRE binary, so we need to install JDK
  wget --continue --progress=dot:giga https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-17.0.9/graalvm-community-jdk-17.0.9_linux-aarch64_bin.tar.gz
  tar xf graalvm-community-*.tar.gz --one-top-level=graalvm --strip-components 1
  export JAVA_HOME=$PWD/graalvm

  wget --continue --progress=dot:giga https://github.com/questdb/questdb/releases/download/${qdb_version}/questdb-${qdb_version}-no-jre-bin.tar.gz
  tar xf questdb*.tar.gz --one-top-level=questdb --strip-components 1
  mkdir questdb/bin
  mv questdb/* questdb/bin
else
  wget --continue --progress=dot:giga https://github.com/questdb/questdb/releases/download/${qdb_version}/questdb-${qdb_version}-rt-linux-x86-64.tar.gz
  tar xf questdb*.tar.gz --one-top-level=questdb --strip-components 1
fi

questdb/bin/questdb.sh start

while ! nc -z localhost 9000; do
  sleep 0.1
done

sed -i 's/query.timeout.sec=60/query.timeout.sec=500/' ~/.questdb/conf/server.conf
sed -i "s|cairo.sql.copy.root=import|cairo.sql.copy.root=$PWD|" ~/.questdb/conf/server.conf
questdb/bin/questdb.sh stop
questdb/bin/questdb.sh start

# Import the data

sudo apt-get install -y pigz
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.csv.gz'
pigz -d -f hits.csv.gz

curl -G --data-urlencode "query=$(cat create.sql)" 'http://localhost:9000/exec'

if [[ "$(nproc)" -ge 96 ]]
then
    # SQL COPY works best on metal instances:
    start=$(date +%s)

    curl -G --data-urlencode "query=copy hits from 'hits.csv' with timestamp 'EventTime' format 'yyyy-MM-dd HH:mm:ss';" 'http://localhost:9000/exec'

    echo 'waiting for import to finish...'
    until [ "$(curl -s -G --data-urlencode "query=select * from sys.text_import_log where phase is null and status='finished';" 'http://localhost:9000/exec' | grep -c '"count":1')" -ge 1 ]; do
        echo '.'
        sleep 5
    done

    end=$(date +%s)
    echo "Load time: $((end - start))"
else
    # On smaller instances use this:
    start=$(date +%s)

    curl -F data=@hits.csv 'http://localhost:9000/imp?name=hits&maxUncommittedRows=5000000'

    echo 'waiting for rows to become readable...'
    until [ "$(curl -s -G --data-urlencode "query=select 1 from (select count() c from hits) where c = 99997497;" 'http://localhost:9000/exec' | grep -c '"count":1')" -ge 1 ]; do
        echo '.'
        sleep 5
    done

    end=$(date +%s)
    echo "Load time: $((end - start))"
fi

# Run queries

./run.sh 2>&1 | tee log.txt

echo -n "Data size: "
du -bcs ~/.questdb/db/hits* | grep total

cat log.txt | \
    grep -P '"timings"|"error"|null' | \
    sed -r -e 's/^.*"error".*$/null/; s/^.*"execute":([0-9]*),.*$/\1/' | \
    awk '{ print ($1) / 1000000000 }' | \
    awk '{ printf "%.3f\n", $1 }' | \
    sed -r -e 's/^0$/null/' | \
    awk '{ if (i % 3 == 0) { printf "[" }; printf $1; if (i % 3 != 2) { printf "," } else { print "]," }; ++i; }'
