# Shared environment of the Iceberg entries, see lib/iceberg/README.md.
# Sourced by the scripts of every `*-iceberg` entry. The entries must refer
# only to the variables below, never to SeaweedFS directly, so that the
# storage can be replaced by a real S3 bucket without touching them.
# The prefix is `LAKE_` rather than `ICEBERG_` on purpose: the programs read
# variables like `ICEBERG_WAREHOUSE` themselves (SeaweedFS does).

# The directory of the benchmark entry (the scripts are run from it).
LAKE_ENTRY_DIR="${LAKE_ENTRY_DIR:-$PWD}"
LAKE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the table is stored. Only `seaweedfs` is implemented for now: a local
# single-process S3-compatible store with a built-in Iceberg REST catalog.
# The planned `s3` mode writes to a temporary prefix of a real S3 bucket.
export LAKE_STORAGE="${LAKE_STORAGE:-seaweedfs}"

case "$LAKE_STORAGE" in
seaweedfs)
    export SEAWEEDFS_VERSION=4.52
    export WEED_BIN="$LAKE_ENTRY_DIR/weed"
    export WEED_DIR="$LAKE_ENTRY_DIR/seaweedfs-data"

    # The S3 API.
    export LAKE_S3_ENDPOINT="http://127.0.0.1:8333"
    export LAKE_S3_ENDPOINT_HOST="127.0.0.1:8333"
    export LAKE_S3_USE_SSL=false
    export LAKE_S3_PATH_STYLE=true

    # The Iceberg REST catalog. A catalog serves one table bucket, the
    # "warehouse"; its REST prefix is the bucket name.
    export LAKE_CATALOG_URI="http://127.0.0.1:8181"
    export LAKE_WAREHOUSE="warehouse"
    export LAKE_WAREHOUSE_LOCATION="s3://warehouse"
    # OAuth2 client credentials flow: the client id and secret are the S3 keys.
    export LAKE_OAUTH_URI="$LAKE_CATALOG_URI/v1/oauth/tokens"
    ;;
*)
    echo "lib/iceberg: unsupported LAKE_STORAGE='$LAKE_STORAGE'" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-clickbench}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-clickbench}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export LAKE_CLIENT_ID="$AWS_ACCESS_KEY_ID"
export LAKE_CLIENT_SECRET="$AWS_SECRET_ACCESS_KEY"

# The table of the benchmark: `clickbench.hits`.
export LAKE_NAMESPACE=clickbench
export LAKE_TABLE=hits
