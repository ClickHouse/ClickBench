# shared by the step scripts
export PGRUST_HOME="${PGRUST_HOME:-$HOME/pgrust}"       # install prefix + data + socket + logs
export PGRUST_PREFIX="$PGRUST_HOME/install"               # the release tarball, untarred (bin/postgres, share/postgresql)
export PGDATA="$PGRUST_HOME/data"
export PGSOCKDIR="$PGRUST_HOME/sock"
export PGPORT="${PGPORT:-5432}"
export PG18BIN="${PG18BIN:-/usr/lib/postgresql/18/bin}"   # initdb + psql from apt.postgresql.org (README "Install")
export HITS_PARQUET="${HITS_PARQUET:-$PGRUST_HOME/hits.parquet}"
# the release tarball per machine architecture, with a .sha256 sidecar; PGRUST_TARBALL (a local file) overrides
export PGRUST_RELEASE="${PGRUST_RELEASE:-v0.4-preview}"
export PGRUST_RELEASE_BASE="${PGRUST_RELEASE_BASE:-https://pgrust.com/downloads/$PGRUST_RELEASE}"   # the v0.2 entry's host (CloudFront -> S3)
case "$(uname -m)" in x86_64) PGRUST_CPU=znver3;; aarch64) PGRUST_CPU=neoverse-v2;; *) PGRUST_CPU=generic;; esac
export PGRUST_BIN_URL="${PGRUST_BIN_URL:-$PGRUST_RELEASE_BASE/pgrust-$PGRUST_RELEASE-$(uname -m)-$PGRUST_CPU.tar.gz}"
export PGRUST_TARBALL="${PGRUST_TARBALL:-}"
export PSQL="$PG18BIN/psql -X -h $PGSOCKDIR -p $PGPORT -U postgres"
