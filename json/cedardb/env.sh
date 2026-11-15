# Shared settings, sourced by the scripts. CedarDB's systemd unit listens on
# /tmp/.s.PGSQL.5432, and the installer creates only the `postgres` role (see
# ../../cedardb/check).
export PGHOST=/tmp
export PGUSER=postgres
export PGDATABASE=postgres
PSQL="psql -X -v ON_ERROR_STOP=1"
