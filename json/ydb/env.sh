# Sourced by the other scripts.
YDB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${YDB_DIR}/ydbd/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
YDBD="${YDB_DIR}/ydbd/bin/ydbd"
# The CLI connects to the storage node, which redirects to the database node.
YDB=("${YDB_DIR}/ydb-cli" -e grpc://localhost:2136 -d /Root/bluesky)
# The YDB CLI reads query parameters from stdin when it is not a terminal: it
# must not consume the stdin of the scripts (the driver feeds them the
# queries file). ./query reads its query before sourcing this file.
exec < /dev/null
