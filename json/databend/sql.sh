# Sourced by the other scripts: run the SQL from stdin with bendsql.
bendsql() {
    ./bin/bendsql -u root -h 127.0.0.1 -P 8000 "$@"
}
