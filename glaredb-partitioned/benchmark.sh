#!/usr/bin/env bash

set -e

repo_root=$(git rev-parse --show-toplevel)
script_dir=$(dirname "$0")

if [[ "$(basename "$repo_root")" == "glaredb" ]]; then
    # Inside glaredb repo, build from source.
    cargo build --release --bin glaredb
    cp "${repo_root}/target/release/glaredb" "${script_dir}/glaredb"
else
    # Not in glaredb repo, use prebuilt binary.
    export GLAREDB_INSTALL_DIR="${script_dir}"
    export GLAREDB_VERSION="v25.5.11"
    curl -fsSL https://glaredb.com/install.sh | sh
fi

# Get the data.
mkdir -p "${script_dir}/data"
pushd "${script_dir}/data"

../lib/download-parquet-partitioned.sh
echo "Data size: $(du -bcs hits*.parquet | grep total)"
echo "Load time: 0"
popd

# Ensure working directory is the script dir. The view that gets created uses a
# relative path.
pushd "${script_dir}"

./run.sh partitioned
cat results.json
