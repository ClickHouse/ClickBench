# Shared settings, sourced by the scripts. The Docker image of the main
# ClickBench entry (../../umbra/install), which listens on 127.0.0.1:5432 with
# the user and password `postgres`.
UMBRA_IMAGE="umbradb/umbra:26.10"
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=postgres
export PGPASSWORD=postgres
PSQL="psql -X -v ON_ERROR_STOP=1"
