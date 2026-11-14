# common.sh — sourced by every script here. Nothing in it is a knob: these are the
# facts the scripts share about where things are.
set -eu
ELOSDB_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELOSDB_BIN="${ELOSDB_BIN:-$ELOSDB_HOME/bin/elosdb}"   # `install` puts it there
ELOSDB_PORT="${ELOSDB_PORT:-5432}"
ELOSDB_DATA="$ELOSDB_HOME/data"                       # data/elosdb is the store,
                                                      # data/clickbench the parquet
# A psql on PATH whose libpq is not loadable answers `command -v` and then dies on
# every invocation, so the probe RUNS it rather than looking for it.
if ! psql --version >/dev/null 2>&1; then
  echo "elosdb: no working psql on PATH — ./install installs postgresql-client" >&2
  exit 1
fi
PSQL=(psql -X -h 127.0.0.1 -p "$ELOSDB_PORT" -U elosdb -d elosdb)
