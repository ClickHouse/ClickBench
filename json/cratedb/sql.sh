# Sourced by the other scripts.
crate_sql() {
    psql -X -U crate -h localhost -w -v ON_ERROR_STOP=1 -t -A "$@"
}
