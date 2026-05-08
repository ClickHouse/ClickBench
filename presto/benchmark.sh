#!/bin/bash

set -e

PRESTO_VERSION=0.297

# Install Docker (Presto's official image bundles its own JRE) and the Presto CLI.
sudo apt-get update -y
sudo apt-get install -y docker.io openjdk-21-jre-headless bc wget

wget --continue --quiet -O presto-cli.jar \
    "https://github.com/prestodb/presto/releases/download/${PRESTO_VERSION}/presto-cli-${PRESTO_VERSION}-executable.jar"
chmod +x presto-cli.jar

# Download the dataset.
wget --continue --progress=dot:giga 'https://datasets.clickhouse.com/hits_compatible/hits.parquet'

# Place the parquet file inside its own directory; the Hive connector
# reads every file in the table's external_location.
mkdir -p data/hits
ln -f hits.parquet data/hits/hits.parquet

# Presto Hive catalog: file metastore on the local filesystem, no external
# Hive Metastore Service or Hadoop required.
mkdir -p etc/catalog
cat > etc/catalog/hive.properties <<'EOF'
connector.name=hive-hadoop2
hive.metastore=file
hive.metastore.catalog.dir=file:///clickbench/metastore
hive.allow-drop-table=true
hive.non-managed-table-writes-enabled=true
EOF

# Presto's default 1 GB heap is too small for ClickBench. Bump it together
# with the matching query-memory configuration.
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

# Start the Presto server. The data dir is exposed at /clickbench so the
# external_location URI in create.sql resolves correctly inside the
# container.
sudo docker rm -f presto 2>/dev/null || true
sudo docker run -d --name presto \
    -p 8081:8080 \
    -v "$PWD/etc/catalog/hive.properties:/opt/presto-server/etc/catalog/hive.properties:ro" \
    -v "$PWD/etc/jvm.config:/opt/presto-server/etc/jvm.config:ro" \
    -v "$PWD/etc/config.properties:/opt/presto-server/etc/config.properties:ro" \
    -v "$PWD/data:/clickbench" \
    prestodb/presto:${PRESTO_VERSION}

# Wait for Presto to finish starting up.
until sudo docker logs presto 2>&1 | grep -q "SERVER STARTED"; do
    sleep 3
done
sleep 3

# Create the schema, the external table over the parquet file and a view
# that exposes the standard ClickBench column types.
LOAD_START=$(date +%s)
java -jar presto-cli.jar --server http://localhost:8081 --file create.sql
LOAD_END=$(date +%s)

# Run the benchmark queries.
./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
echo "Data size: $(stat -c %s hits.parquet)"
