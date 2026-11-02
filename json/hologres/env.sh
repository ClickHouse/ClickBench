# Shared settings, sourced by the scripts. The connection is in PG_USER,
# PG_PASSWORD, PG_HOSTNAME and PG_PORT (see README.md).
HOLOGRES_DB=jsonbench

# psql connected to the database given as the first argument.
hg_psql() {
    local db="$1"
    shift
    PGUSER="${PG_USER}" PGPASSWORD="${PG_PASSWORD}" \
        psql -h "${PG_HOSTNAME}" -p "${PG_PORT}" -d "${db}" -v ON_ERROR_STOP=1 "$@"
}
