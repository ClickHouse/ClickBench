#!/bin/bash

set -e

# Trino's S3 client uses the AWS default credentials chain, which fails on
# anonymous public buckets, and Trino has no built-in flag for unsigned
# requests (see trinodb/trino#27512, PR #27758 closed unmerged). To read
# the public bucket we drop a tiny shim that returns AnonymousAWSCredentials
# into the legacy HDFS S3 plugin and point trino.s3.credentials-provider
# at it.

sudo apt-get update -y
sudo apt-get install -y docker.io bc

mkdir -p data/meta etc/catalog shim
# The Trino container runs as uid 1000 ("trino") and writes the file
# metastore into data/meta. Make sure that uid can write here even when
# benchmark.sh runs as root (cloud-init).
sudo chown 1000:1000 data/meta

cat > shim/S3AnonymousProvider.java <<'EOF'
import com.amazonaws.auth.AWSCredentials;
import com.amazonaws.auth.AWSCredentialsProvider;
import com.amazonaws.auth.AnonymousAWSCredentials;
import org.apache.hadoop.conf.Configuration;
import java.net.URI;

public class S3AnonymousProvider implements AWSCredentialsProvider {
    public S3AnonymousProvider(URI uri, Configuration conf) {}
    public AWSCredentials getCredentials() { return new AnonymousAWSCredentials(); }
    public void refresh() {}
}
EOF

# Compile the shim against the AWS SDK + Hadoop jars bundled in the trino
# image. Target Java 11 bytecode for portability.
sudo docker run --rm \
    -v "$PWD/shim:/shim" \
    --entrypoint sh trinodb/trino:latest -c '
        set -e
        cd /shim
        CP="/usr/lib/trino/plugin/hive/hdfs/com.amazonaws_aws-java-sdk-core-1.12.797.jar:/usr/lib/trino/plugin/hive/hdfs/io.trino.hadoop_hadoop-apache-3.3.5-3.jar"
        javac --release 11 -cp "$CP" S3AnonymousProvider.java
        jar cf S3AnonymousProvider.jar S3AnonymousProvider.class
    '

cat > etc/catalog/hive.properties <<'EOF'
connector.name=hive
hive.metastore=file
hive.metastore.catalog.dir=local:///meta
local.location=/data
fs.native-local.enabled=true
fs.hadoop.enabled=true
hive.config.resources=/etc/trino/core-site.xml
hive.non-managed-table-writes-enabled=true
EOF

cat > etc/core-site.xml <<'EOF'
<?xml version="1.0"?>
<configuration>
    <property>
        <name>trino.s3.credentials-provider</name>
        <value>S3AnonymousProvider</value>
    </property>
    <property>
        <name>trino.s3.endpoint</name>
        <value>https://s3.eu-central-1.amazonaws.com</value>
    </property>
    <property>
        <name>trino.s3.region</name>
        <value>eu-central-1</value>
    </property>
</configuration>
EOF

sudo docker rm -f trino 2>/dev/null || true
sudo docker run -d --name trino \
    -p 8080:8080 \
    -v "$PWD/etc/catalog/hive.properties:/etc/trino/catalog/hive.properties:ro" \
    -v "$PWD/etc/core-site.xml:/etc/trino/core-site.xml:ro" \
    -v "$PWD/data/meta:/data/meta" \
    -v "$PWD/shim/S3AnonymousProvider.jar:/usr/lib/trino/plugin/hive/hdfs/S3AnonymousProvider.jar:ro" \
    trinodb/trino:latest

until sudo docker logs trino 2>&1 | grep -q "SERVER STARTED"; do
    sleep 3
done
sleep 3

LOAD_START=$(date +%s)
sudo docker cp create.sql trino:/tmp/create.sql
sudo docker exec -i trino trino --file /tmp/create.sql
LOAD_END=$(date +%s)

./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
# Data is read from S3 on demand; report the published single-file size.
echo "Data size: 14779976446"
