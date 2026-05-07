#!/bin/bash

set -e

# Trino's native S3 driver requires AWS credentials and signs every request,
# so it cannot read directly from the anonymous public bucket. Mount the
# bucket via s3fs-fuse instead and let Trino read it as a local filesystem.
# All data is fetched on demand from S3 — nothing is downloaded ahead of
# time.

sudo apt-get update -y
sudo apt-get install -y docker.io s3fs bc

# s3fs needs user_allow_other so the docker daemon (running as root) can
# traverse the FUSE mount owned by the calling user.
grep -q '^user_allow_other' /etc/fuse.conf || \
    echo user_allow_other | sudo tee -a /etc/fuse.conf >/dev/null

mkdir -p data/bucket data/meta
# The Trino container runs as uid 1000 ("trino") and writes the file
# metastore into data/meta. Make sure that uid can write here even when
# benchmark.sh runs as root (cloud-init).
sudo chown 1000:1000 data/meta
fusermount -u data/bucket 2>/dev/null || true
s3fs clickhouse-public-datasets data/bucket \
    -o public_bucket=1 \
    -o url=https://s3.eu-central-1.amazonaws.com \
    -o allow_other \
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
connector.name=hive
hive.metastore=file
hive.metastore.catalog.dir=local:///meta
local.location=/data
fs.native-local.enabled=true
hive.non-managed-table-writes-enabled=true
EOF

sudo docker rm -f trino 2>/dev/null || true
sudo docker run -d --name trino \
    -p 8080:8080 \
    --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor:unconfined \
    -v "$PWD/etc/catalog/hive.properties:/etc/trino/catalog/hive.properties:ro" \
    -v "$PWD/data/meta:/data/meta" \
    -v "$PWD/data/bucket:/data/bucket:ro" \
    trinodb/trino:latest

until sudo docker logs trino 2>&1 | grep -q "SERVER STARTED"; do
    sleep 3
done
sleep 3

# Verify the s3fs-mounted parquet is visible inside the container before
# running CREATE TABLE. Without this, if the FUSE mount didn't propagate
# into docker's mount namespace (or s3fs hasn't primed its metadata cache
# yet), Trino observes the external_location as missing and tries to
# mkdir on the read-only mount, which fails with
# "Failed to create directory: local:///bucket/hits_compatible/athena".
# The listing also serves to warm s3fs's metadata cache.
if ! sudo docker exec trino sh -c 'ls /data/bucket/hits_compatible/athena/hits.parquet' >/dev/null 2>&1; then
    echo "FATAL: hits.parquet is not visible inside the trino container." >&2
    echo "Container view of /data/bucket:" >&2
    sudo docker exec trino ls -la /data/bucket 2>&1 | head >&2 || true
    echo "Host view:" >&2
    ls -la data/bucket/hits_compatible/athena/ 2>&1 | head >&2 || true
    exit 1
fi

LOAD_START=$(date +%s)
sudo docker cp create.sql trino:/tmp/create.sql
sudo docker exec -i trino trino --file /tmp/create.sql
LOAD_END=$(date +%s)

./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
# Data is read from S3 on demand; report the published single-file size.
echo "Data size: 14779976446"
