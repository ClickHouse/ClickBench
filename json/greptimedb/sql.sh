# Sourced by the other scripts: greptime_sql <query> prints the first value of
# the first row of the result of a query sent to the HTTP SQL API.
greptime_sql() {
    local response
    response=$(curl -sS --fail http://localhost:4000/v1/sql \
        --data-urlencode "sql=$1" --data-urlencode "format=greptimedb_v1") || return 1
    printf '%s\n' "${response}" | jq -er '.output[0].records.rows[0][0]'
}
