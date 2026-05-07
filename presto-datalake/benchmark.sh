#!/bin/bash

set -e

PRESTO_VERSION=0.297

# Presto's S3 driver requires AWS credentials and signs every request, so
# it cannot read directly from the anonymous public bucket. Mount the
# bucket via s3fs-fuse and let Presto read it as a local filesystem; data
# is fetched on demand from S3.

sudo apt-get update -y
sudo apt-get install -y docker.io s3fs openjdk-21-jre-headless bc wget

wget --continue --quiet -O presto-cli.jar \
    "https://github.com/prestodb/presto/releases/download/${PRESTO_VERSION}/presto-cli-${PRESTO_VERSION}-executable.jar"
chmod +x presto-cli.jar

# s3fs needs user_allow_other so the docker daemon (running as root) can
# traverse the FUSE mount owned by the calling user.
grep -q '^user_allow_other' /etc/fuse.conf || \
    echo user_allow_other | sudo tee -a /etc/fuse.conf >/dev/null

mkdir -p data/bucket data/meta
fusermount -u data/bucket 2>/dev/null || true
s3fs clickhouse-public-datasets data/bucket \
    -o public_bucket=1 \
    -o url=https://s3.eu-central-1.amazonaws.com \
    -o allow_other \
    -o ro \
    -o use_cache=/tmp/s3fs-cache

mkdir -p etc/catalog
cat > etc/catalog/hive.properties <<'EOF'
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=file:///data/meta
hive.allow-drop-table=true
hive.non-managed-table-writes-enabled=true
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
    --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
    -v "$PWD/etc/catalog/hive.properties:/opt/presto-server/etc/catalog/hive.properties:ro" \
    -v "$PWD/etc/jvm.config:/opt/presto-server/etc/jvm.config:ro" \
    -v "$PWD/etc/config.properties:/opt/presto-server/etc/config.properties:ro" \
    -v "$PWD/data/meta:/data/meta" \
    -v "$PWD/data/bucket:/data/bucket:ro" \
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
echo "Data size: 14779976446"
