#!/bin/bash
#set -x
VERSION_ARR=(${1//[-v]/ })
VERSION=${VERSION_ARR[0]}
FILE_NAME=${VERSION}.json
echo "$VERSION"
sudo ~/clickhouse stop
sudo DEBIAN_FRONTEND=noninteractive apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get remove --yes clickhouse-client clickhouse-server clickhouse-common clickhouse-common-static ||:
sudo DEBIAN_FRONTEND=noninteractive apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" --allow-downgrades --yes clickhouse-client=$VERSION clickhouse-server=$VERSION clickhouse-common=$VERSION ||:
sudo DEBIAN_FRONTEND=noninteractive apt-get install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confnew" --allow-downgrades --yes clickhouse-client=$VERSION clickhouse-server=$VERSION clickhouse-common-static=$VERSION ||: 
#sudo service clickhouse-server restart
sudo ~/clickhouse stop
sudo ~/clickhouse start
sleep 3
VERSION_CH=`clickhouse-client --query 'select version()'`
if [[ ${VERSION} != ${VERSION_CH} ]]
then 
	echo "ClickHouse was not updated. Expected: ${VERSION} actual: ${VERSION_CH}"
	exit 1
fi

sleep 5
echo '{
        "version":       "'$VERSION'",
	"actual_version": "'$VERSION_CH'",
        "result":
        [' | tee $FILE_NAME

bash ./benchmarks.sh >> $FILE_NAME

sed -i '$ s/,$//' $FILE_NAME

echo '    ]
}' >> $FILE_NAME
