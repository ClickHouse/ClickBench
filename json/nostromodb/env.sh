# Shared settings, sourced by the scripts.
NOSTROMODB_IMAGE="svilenmihaylov/nostromodb:latest"
NOSTROMODB_DB_DIR=/var/lib/nostromodb/bluesky

# Runs the statements given as the argument against the database. The dataset
# directory is mounted as /data, writable, as in the original PR (IMPORT
# failed with a read-only mount, possibly for that reason), the database
# directory as /db.
nostromodb() {
    sudo docker run --rm --ulimit nofile=65535:65535 \
        -v "${BENCH_DATA_DIR:-/data/bluesky}":/data \
        -v "${NOSTROMODB_DB_DIR}":/db \
        "${NOSTROMODB_IMAGE}" --db_path /db/catalog.json --c "$1"
}
