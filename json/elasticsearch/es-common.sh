# Sourced by the scripts of this directory (and of ../elasticsearch-no-source),
# which the driver runs from the system directory.
#
# Security is enabled, as in the original JSONBench: HTTPS with the
# self-signed certificate made at the installation, and the password of the
# `elastic` user, which ./start resets once and stores in .elastic_password.

ES_URL="https://localhost:9200"
ES_PASSWORD_FILE="${PWD}/.elastic_password"
ES_INDEX="bluesky"

es_password() {
    cat "${ES_PASSWORD_FILE}"
}

# curl with the credentials; fails on HTTP errors, printing the body.
es_curl() {
    curl -sS -k --fail-with-body -u "elastic:$(es_password)" -H 'Content-Type: application/json' "$@"
}

# Exit status 0 iff the stored password is accepted.
es_auth_ok() {
    [ -s "${ES_PASSWORD_FILE}" ] || return 1
    local code
    code=$(curl -sS -k -o /dev/null -w '%{http_code}' --max-time 10 -u "elastic:$(es_password)" "${ES_URL}/" 2>/dev/null) || return 1
    [ "${code}" = "200" ]
}
