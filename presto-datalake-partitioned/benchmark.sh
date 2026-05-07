#!/bin/bash

set -e

PRESTO_VERSION=0.297

# Presto's S3 driver requires AWS credentials and signs every request, so
# it cannot read directly from the anonymous public bucket. Mount the
# bucket via s3fs-fuse and let Presto read it as a local filesystem.

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
# uid/gid 1000 so files inside the FUSE mount appear owned by a normal
# user — without this, when benchmark.sh runs as root (cloud-init), files
# appear root-owned with mode 0750 and a non-root container user cannot
# traverse the bucket subdirectories.
# The cache dir must also be writable as that uid.
sudo mkdir -p /tmp/s3fs-cache
sudo chown 1000:1000 /tmp/s3fs-cache
# Unmount on exit so cloud-init's "du -b --max-depth=2" doesn't hang
# walking the FUSE mount after we're done.
trap 'fusermount -u data/bucket 2>/dev/null || true' EXIT
s3fs clickhouse-public-datasets data/bucket \
    -o public_bucket=1 \
    -o url=https://s3.eu-central-1.amazonaws.com \
    -o allow_other \
    -o uid=1000 \
    -o gid=1000 \
    -o ro \
    -o use_cache=/tmp/s3fs-cache

# apt-get installed docker.io and started docker.service before we
# mounted s3fs, so the daemon's mount namespace doesn't include the FUSE
# mount and bind-mounting data/bucket into the container produces an
# empty directory. Restart the daemon so its namespace picks up the
# current host mounts.
sudo systemctl restart docker

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

# Verify the s3fs-mounted parquet directory is visible inside the
# container before running CREATE TABLE. Without this, if the FUSE mount
# didn't propagate into docker's mount namespace (or s3fs hasn't primed
# its metadata cache yet), Presto observes the external_location as
# missing and tries to mkdir on the read-only mount, which fails. The
# listing also serves to warm s3fs's metadata cache.
if ! sudo docker exec presto sh -c 'ls /data/bucket/hits_compatible/athena_partitioned/' >/dev/null 2>&1; then
    echo "FATAL: athena_partitioned/ is not visible inside the presto container." >&2
    echo "Container view of /data/bucket:" >&2
    sudo docker exec presto ls -la /data/bucket 2>&1 | head >&2 || true
    echo "Host view:" >&2
    ls -la data/bucket/hits_compatible/athena_partitioned/ 2>&1 | head >&2 || true
    exit 1
fi

LOAD_START=$(date +%s)
java -jar presto-cli.jar --server http://localhost:8081 --file create.sql
LOAD_END=$(date +%s)

./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
echo "Data size: 14737666736"
