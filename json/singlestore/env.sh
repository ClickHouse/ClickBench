# shellcheck shell=bash
# Sourced by the other scripts.

# The password of the root user of the local cluster, set by ./install. It is
# not a secret: the cluster listens on the loopback interface only.
export MYSQL_PWD="${SINGLESTORE_ROOT_PASSWORD:-jsonbench}"

# Toolbox runs as root only when configured so, see ./install.
export HOME="${HOME:-/root}"

ss_mysql() {
    mysql -h127.0.0.1 -P3306 -uroot "$@"
}
