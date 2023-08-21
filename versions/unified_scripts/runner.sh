#!/bin/bash
#set -x
VERSION_ARR=(${1//[-v]/ })
VERSION=${VERSION_ARR[0]}
FILE_NAME=${VERSION}.json
DATE=$2

echo "$VERSION $DATE"
sudo ~/clickhouse stop
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install --allow-downgrades --yes clickhouse-client=$VERSION clickhouse-server=$VERSION clickhouse-common=$VERSION ||:
sudo DEBIAN_FRONTEND=noninteractive apt-get install --allow-downgrades --yes clickhouse-client=$VERSION clickhouse-server=$VERSION clickhouse-common-static=$VERSION ||: 
#sudo service clickhouse-server restart
sudo ~/clickhouse start
clickhouse-client --query 'select version()' --progress 0
sleep 5
echo '{
        "version":       "'$VERSION'",
        "result":
        [' | tee $FILE_NAME

bash ./benchmarks.sh >> $FILE_NAME

sed -i '$ s/,$//' $FILE_NAME

echo '    ]
}' >> $FILE_NAME
