#!/bin/bash
# For each configuration: create the cluster, run the benchmark, write the
# results JSON, and delete the cluster.
#
#   ./run-all.sh [<node type>:<nodes> ...]      (provisioned, from redshift/)
#   ../redshift-serverless/run-all.sh [<rpu> ...]
#
# Logs go to log-<configuration>.txt. Clusters are deleted even if the
# benchmark fails; set KEEP_CLUSTER=1 to keep them.
set -u
cd "$(dirname "$0")"
date=$(date +%F)

# The entry directory decides the mode (this script is symlinked into
# ../redshift-serverless).
if [ "$(basename "$(pwd)")" = redshift-serverless ]; then
    export REDSHIFT_MODE=serverless
    default_configs=(128)
else
    export REDSHIFT_MODE=provisioned
    # Every node type at 1 to 4 nodes; the larger types are multi-node only.
    default_configs=(
        ra3.large:{1,2,3,4} ra3.xlplus:{1,2,3,4} ra3.4xlarge:{2,3,4} ra3.16xlarge:{2,3,4}
        rg.large:{1,2,3,4} rg.xlarge:{2,3,4} rg.4xlarge:{2,3,4} rg.12xlarge:{2,3,4}
    )
fi
configs=("$@")
[ "${#configs[@]}" -gt 0 ] || configs=("${default_configs[@]}")

./install

for config in "${configs[@]}"; do
    if [ "$REDSHIFT_MODE" = serverless ]; then
        export REDSHIFT_RPU="$config"
    else
        export REDSHIFT_NODE_TYPE="${config%%:*}" REDSHIFT_NODES="${config##*:}"
    fi
    log="log-${config//:/x}.txt"
    echo "=== $config -> $log"
    if ./provision && ./benchmark.sh > "$log" 2>&1; then
        ./make-result "$log" "$date" || echo "make-result failed for $config"
    else
        echo "benchmark failed for $config; see $log"
    fi
    [ -n "${KEEP_CLUSTER:-}" ] || ./deprovision
done
