# Sourced by the scripts of this directory, which the driver runs from the
# system directory.
#
# The security plugin is enabled with the demo configuration that the package
# installs (HTTPS with self-signed certificates, the `admin` user), as in the
# Elasticsearch entry. Since OpenSearch 2.12 the demo configuration needs an
# initial admin password, which is fixed here: the server only listens on
# localhost.

OS_URL="https://localhost:9200"
OS_USER="admin"
OS_PASSWORD="JsonBench_Bluesky-2026!"
OS_INDEX="bluesky"

# curl with the credentials; fails on HTTP errors, printing the body.
os_curl() {
    curl -sS -k --fail-with-body -u "${OS_USER}:${OS_PASSWORD}" -H 'Content-Type: application/json' "$@"
}
