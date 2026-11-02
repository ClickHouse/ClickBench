# shellcheck shell=bash
# Sourced by the other scripts.
STARROCKS_HOME="$(pwd)/starrocks"
export STARROCKS_HOME
JAVA_HOME="/usr/lib/jvm/java-17-openjdk-$(dpkg --print-architecture)"
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

sr_mysql() {
    mysql -h127.0.0.1 -P9030 -uroot "$@"
}

# Whether at least one BE is alive. The position of the Alive column of
# SHOW BACKENDS differs between versions, so find it by the header.
sr_backend_alive() {
    sr_mysql -B -e 'SHOW BACKENDS' 2>/dev/null \
        | awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) if ($i == "Alive") c = i; next }
                      c && tolower($c) == "true" { found = 1 }
                      END { exit !found }'
}
