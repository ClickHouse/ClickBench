# shared by the step scripts
# The server and initdb refuse to run as root, and ClickBench's automation runs these scripts as root
# (HOME=/root): everything the server touches lives under a directory owned by the `postgres` system
# user (install creates it when missing) and the server-side steps run through $AS_PG.
export PGRUST_USER="${PGRUST_USER:-postgres}"
export PGRUST_HOME="${PGRUST_HOME:-/var/lib/pgrust}"       # install prefix + data + socket + logs (owned by $PGRUST_USER)
if [ "$(id -un)" = "$PGRUST_USER" ]; then AS_PG=""; else AS_PG="sudo -u $PGRUST_USER"; fi
export AS_PG
export PGRUST_PREFIX="$PGRUST_HOME/install"               # the release tarball, untarred: bin/{postgres,initdb,psql} + bin/share
export PGDATA="$PGRUST_HOME/data"
export PGSOCKDIR="$PGRUST_HOME/sock"
export PGPORT="${PGPORT:-5432}"
export HITS_PARQUET="${HITS_PARQUET:-$PGRUST_HOME/hits.parquet}"
# The public release tarball for this machine, checked against its .sha256 sidecar: select-build picks the
# CPU-tuned build when the CPU matches one (Neoverse-V2, AMD Zen 3 or newer), else the generic build of the
# architecture. PGRUST_TARBALL (a local file) or PGRUST_BIN_URL overrides.
export PGRUST_RELEASE="${PGRUST_RELEASE:-0.4-beta}"
export PGRUST_RELEASE_BASE="${PGRUST_RELEASE_BASE:-https://pgrust.com/downloads/v$PGRUST_RELEASE}"
PGRUST_BUILD_CHOICE=$("$(dirname "${BASH_SOURCE[0]}")/select-build")
export PGRUST_BUILD_CHOICE
export PGRUST_BIN_URL="${PGRUST_BIN_URL:-$PGRUST_RELEASE_BASE/pgrust-$PGRUST_RELEASE-${PGRUST_BUILD_CHOICE%% *}.tar.gz}"
export PGRUST_TARBALL="${PGRUST_TARBALL:-}"
export PSQL="$PGRUST_PREFIX/bin/psql -X -h $PGSOCKDIR -p $PGPORT -U postgres"
