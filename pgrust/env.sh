# Shared paths for the pgrust ClickBench entry. Sourced by the sibling
# scripts; not executable on its own.

PGRUST_VERSION=0.2
# The server binary, installed by ./install (sha256-verified download).
PGRUST_BIN=/usr/local/bin/pgrust-postgres
# The data directory. A fixed, world-traversable path rather than $PWD:
# the server runs as the `postgres` system user, which cannot traverse
# into e.g. /root if the checkout lives there.
PGDATA_DIR=/var/lib/pgrust/data
SERVER_LOG=/var/lib/pgrust/server.log
# Unix socket directory (the server does not listen on TCP).
PGSOCK_DIR=/var/run/pgrust
# C PostgreSQL 18 (PGDG) provides initdb and psql; pgrust cannot bootstrap
# a data directory itself and ships no client.
PG18_BIN=/usr/lib/postgresql/18/bin
# pgrust reads timezone data and misc share files from a C PostgreSQL
# share directory at runtime.
PGSHARE_DIR=/usr/share/postgresql/18
TZDATA_DIR=/usr/share/zoneinfo
# Where ./load moves hits.parquet before the server-side COPY. /var/tmp is
# world-traversable, so the server (running as `postgres`) can read it
# regardless of where the checkout lives.
HITS_FILE=/var/tmp/hits.parquet

PSQL="psql -h $PGSOCK_DIR -p 5432 -U postgres"
