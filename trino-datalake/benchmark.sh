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

LOAD_START=$(date +%s)
sudo docker cp create.sql trino:/tmp/create.sql
sudo docker exec -i trino trino --file /tmp/create.sql
LOAD_END=$(date +%s)

./run.sh 2>&1 | tee log.txt

echo "Load time: $((LOAD_END - LOAD_START))"
# Data is read from S3 on demand; report the published single-file size.
echo "Data size: 14779976446"
