#!/bin/bash

set -e

PRESTO_VERSION=0.297

# Presto's S3 client uses the AWS default credentials chain, which fails on
# anonymous public buckets. To read the public bucket we drop a tiny shim
# that returns AnonymousAWSCredentials into the hive-hadoop2 plugin and
# point presto.s3.credentials-provider at it.

sudo apt-get update -y
sudo apt-get install -y docker.io openjdk-21-jre-headless bc wget

wget --continue --quiet -O presto-cli.jar \
    "https://github.com/prestodb/presto/releases/download/${PRESTO_VERSION}/presto-cli-${PRESTO_VERSION}-executable.jar"
chmod +x presto-cli.jar

mkdir -p data/meta etc/catalog shim
# The trino container used to compile the shim runs as uid 1000. Make
# sure that uid can write here even when benchmark.sh runs as root
# (cloud-init).
sudo chown 1000:1000 shim

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

# Compile the shim against AWS SDK + Hadoop jars bundled in the presto
# image. The presto image ships with a JRE only, so use the trino image
# for the JDK and target Java 11 bytecode for compatibility.
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
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=file:///data/meta
hive.config.resources=/etc/presto/core-site.xml
hive.non-managed-table-writes-enabled=true
EOF

cat > etc/core-site.xml <<'EOF'
<?xml version="1.0"?>
<configuration>
    <property>
        <name>presto.s3.credentials-provider</name>
        <value>S3AnonymousProvider</value>
    </property>
    <property>
        <name>presto.s3.endpoint</name>
        <value>https://s3.eu-central-1.amazonaws.com</value>
    </property>
</configuration>
EOF

cat > etc/jvm.config <<'EOF'
-server
-Xmx48G
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+UseGCOverheadLimit
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:+ExitOnOutOfMemoryError
-Djdk.attach.allowAttachSelf=true
--add-opens=java.base/java.io=ALL-UNNAMED
--add-opens=java.base/java.lang=ALL-UNNAMED
--add-opens=java.base/java.lang.ref=ALL-UNNAMED
--add-opens=java.base/java.lang.reflect=ALL-UNNAMED
--add-opens=java.base/java.net=ALL-UNNAMED
--add-opens=java.base/java.nio=ALL-UNNAMED
--add-opens=java.base/java.security=ALL-UNNAMED
--add-opens=java.base/javax.security.auth=ALL-UNNAMED
--add-opens=java.base/javax.security.auth.login=ALL-UNNAMED
--add-opens=java.base/java.text=ALL-UNNAMED
--add-opens=java.base/java.util=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED
--add-opens=java.base/java.util.concurrent.locks=ALL-UNNAMED
--add-opens=java.base/java.util.regex=ALL-UNNAMED
--add-opens=java.base/sun.nio.cs=ALL-UNNAMED
--add-opens=java.base/sun.security.action=ALL-UNNAMED
--add-opens=java.base/sun.security.util=ALL-UNNAMED
--add-opens=java.base/sun.util.calendar=ALL-UNNAMED
--add-opens=java.management/javax.management=ALL-UNNAMED
--add-opens=java.management/javax.management.openmbean=ALL-UNNAMED
--add-opens=java.security.jgss/sun.security.krb5=ALL-UNNAMED
--add-opens=java.sql/java.sql=ALL-UNNAMED
EOF

cat > etc/config.properties <<'EOF'
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
discovery-server.enabled=true
discovery.uri=http://localhost:8080
query.max-memory=24GB
query.max-memory-per-node=16GB
query.max-total-memory-per-node=24GB
memory.heap-headroom-per-node=8GB
EOF

sudo docker rm -f presto 2>/dev/null || true
sudo docker run -d --name presto \
    -p 8081:8080 \
    -v "$PWD/etc/catalog/hive.properties:/opt/presto-server/etc/catalog/hive.properties:ro" \
    -v "$PWD/etc/jvm.config:/opt/presto-server/etc/jvm.config:ro" \
    -v "$PWD/etc/config.properties:/opt/presto-server/etc/config.properties:ro" \
    -v "$PWD/etc/core-site.xml:/etc/presto/core-site.xml:ro" \
    -v "$PWD/data/meta:/data/meta" \
    -v "$PWD/shim/S3AnonymousProvider.jar:/opt/presto-server/plugin/hive-hadoop2/S3AnonymousProvider.jar:ro" \
    prestodb/presto:${PRESTO_VERSION}

until sudo docker logs presto 2>&1 | grep -q "SERVER STARTED"; do
    sleep 3
done
sleep 3

LOAD_START=$(date +%s)
java -jar presto-cli.jar --server http://localhost:8081 --file create.sql
LOAD_END=$(date +%s)

./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
echo "Data size: 14737666736"
