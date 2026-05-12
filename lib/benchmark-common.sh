#!/bin/bash

# Shared ClickBench driver.
#
# A per-system benchmark.sh sets a few env vars and then exec's this script.
# This script is designed to be invoked from a system directory (e.g.
# clickhouse/), so all script paths below are relative to the system dir.
#
# Required env:
#   BENCH_DOWNLOAD_SCRIPT  Name of a top-level download-hits-* script to fetch
#                          the dataset (e.g. "download-hits-parquet-single").
#                          Set to empty string for systems that read directly
#                          from a remote source (S3 datalake, remote services).
#
# Optional env:
#   BENCH_RESTARTABLE      "yes" (default) or "no". Tells the driver whether
#                          stop/start is meaningful for this system.
#                            yes — system has a daemon (or in-process server
#                                  wrapper) whose lifecycle matters. The
#                                  cold cycle is stop -> wait_stopped ->
#                                  drop_caches -> start -> check.
#                            no  — system has no daemon: ./start, ./stop,
#                                  and ./check are no-ops (embedded CLIs
#                                  like clickhouse-local, duckdb,
#                                  datafusion, sqlite, hyper, chdb,
#                                  spark variants).
#                                  Restarting would do nothing, and worse,
#                                  bench_wait_stopped would spin until its
#                                  60s timeout on every cold cycle because
#                                  ./check keeps succeeding. We skip the
#                                  stop/start/check dance entirely and
#                                  just drop_caches between queries.
#   BENCH_DURABLE          "yes" (default) or "no". Tells the driver whether
#                          the system's data survives a stop+start.
#                            yes — data is on disk (daemons like clickhouse,
#                                  or CLI tools like duckdb that operate on
#                                  a .db file). Between queries we just
#                                  restart for a cold process and rely on
#                                  drop_caches for OS pagecache.
#                            no  — data lives in process memory (in-process
#                                  servers: pandas/polars/duckdb-dataframe/
#                                  duckdb-memory/chdb-dataframe/daft/sirius).
#                                  Between queries we restart AND re-run
#                                  ./load, then roll the reload wall-clock
#                                  into the first ("cold") try so the cold
#                                  number genuinely measures load+query
#                                  rather than a warm query against a
#                                  freshly-loaded RAM dataset.
#   BENCH_TRIES            Number of times each query is run. Default 3.
#   BENCH_QUERIES_FILE     Path to a queries file, one query per line.
#                          Default "queries.sql" (in the system dir).
#   BENCH_CHECK_TIMEOUT    Seconds to wait for ./check to succeed. Default 300.
#   BENCH_CONCURRENT_CONNECTIONS
#                          Number of parallel workers in the QPS test
#                          that runs after the cold/warm sweep. Default 10.
#   BENCH_CONCURRENT_DURATION
#                          Wall-clock window for the QPS test, in seconds.
#                          Default 600.
#   BENCH_CONCURRENT_SEED  Seed shared across systems so that connection
#                          N hits the same query order on every engine
#                          (the per-connection permutation is derived
#                          deterministically from this seed + the
#                          connection index). Default "clickbench".

set -e

# Defensive HOME export: cloud-init.sh.in stamps it too, but if an
# operator's local checkout predates that fix, the install/load/query
# scripts inherit an empty HOME and tools that follow XDG conventions
# (vcpkg, duckdb extension cache, go mod cache, gizmosql installer)
# fail in confusing ways. Pin to /root so every per-system step has a
# real home directory regardless.
export HOME="${HOME:-/root}"

# BENCH_DOWNLOAD_SCRIPT must be set (possibly to empty for "no download").
: "${BENCH_DOWNLOAD_SCRIPT?BENCH_DOWNLOAD_SCRIPT is required (set empty to skip)}"
: "${BENCH_RESTARTABLE:=yes}"
: "${BENCH_DURABLE:=yes}"
: "${BENCH_TRIES:=3}"
: "${BENCH_QUERIES_FILE:=queries.sql}"
: "${BENCH_CHECK_TIMEOUT:=300}"
: "${BENCH_CONCURRENT_CONNECTIONS:=10}"
: "${BENCH_CONCURRENT_DURATION:=600}"
: "${BENCH_CONCURRENT_SEED:=clickbench}"

# Resolve the directory containing this script so we can find sibling
# helpers (download-hits-*).
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bench_check_loop() {
    local i last_err
    for i in $(seq 1 "$BENCH_CHECK_TIMEOUT"); do
        if last_err=$(./check 2>&1 >/dev/null); then
            return 0
        fi
        sleep 1
    done
    echo "bench: ./check did not succeed within ${BENCH_CHECK_TIMEOUT}s" >&2
    if [ -n "$last_err" ]; then
        echo "bench: last ./check stderr was:" >&2
        printf '%s\n' "$last_err" | sed 's/^/    /' >&2
    fi
    return 1
}

# Wait for ./check to start failing — i.e. the system is actually down,
# not merely told to stop. Engines that mmap their data files (Umbra,
# Hyper, etc.) keep the OS pagecache pinned until the process is gone,
# so we have to wait before drop_caches has any effect. Times out after
# 60s and proceeds anyway.
bench_wait_stopped() {
    local i
    for i in $(seq 1 60); do
        if ! ./check >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "bench: system did not stop within 60s; proceeding anyway" >&2
    return 0
}

bench_flush_caches() {
    sync
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
}

bench_install() {
    ./install
}

bench_start() {
    # Tolerate non-zero exit from ./start: many engines' start commands return
    # non-zero when the server is already up but leave the system in the
    # desired state. The check loop is the authoritative readiness signal.
    #
    # Silence ./start: many daemons (clickhouse-server, postgres, ...) print
    # progress lines to stdout/stderr that would otherwise interleave with
    # the parseable [t1,t2,t3]/Load time/Data size lines in the benchmark log.
    ./start >/dev/null 2>&1 || true
    bench_check_loop
}

bench_stop() {
    # Silence ./stop for the same reason as ./start.
    ./stop >/dev/null 2>&1
}

bench_download() {
    if [ -z "$BENCH_DOWNLOAD_SCRIPT" ]; then
        return 0
    fi
    "$LIB_DIR/$BENCH_DOWNLOAD_SCRIPT"
}

bench_load() {
    local start_t end_t
    start_t=$(date +%s.%N)
    ./load
    # Force a sync inside the measured window: ingest writers (postgres
    # COPY, ClickHouse INSERT, DuckDB CTAS, etc.) hand back well before
    # their pages have hit disk, and individual per-system load scripts
    # were inconsistent about doing it themselves. Without this the first
    # cold query then pays the writeback as if it were query work, which
    # is unfair to the systems whose load script DID call sync. Doing it
    # here once, for everyone, makes load_time the honest "data is on
    # disk" wall-clock and removes the per-system inconsistency.
    sync
    end_t=$(date +%s.%N)
    # Print "Load time: <secs>" matching the existing log shape that
    # play.clickhouse.com expects.
    awk -v s="$start_t" -v e="$end_t" 'BEGIN { printf "Load time: %.3f\n", e - s }'

    # Defense against silent partial loads. Several DBs (umbra, mysql,
    # postgres, mongodb, cratedb) survive an earlyoom / kernel-OOM kill
    # mid-COPY by restarting and exposing a half-empty table; queries
    # then run in microseconds against a near-empty result set and the
    # run looks green. Catch this here, before we fire 43 meaningless
    # query iterations:
    #
    #   1. Re-run ./check — confirms the server is still up.
    #   2. Run ./data-size — confirms enough bytes actually landed on
    #      disk. ClickBench's hits dataset compresses to >5 GB on every
    #      system in the catalog, so anything smaller is partial.
    #
    # bench_main calls ./data-size again later to log the value; we
    # don't cache the number here because some systems (those that
    # accumulate background compaction or merge files post-load) report
    # a meaningfully different size by the time queries finish.
    if ! ./check >/dev/null 2>&1; then
        echo "bench: ./check failed after ./load — server crashed mid-load?" >&2
        return 1
    fi

    local size
    size=$(./data-size 2>/dev/null || echo 0)
    if ! [[ "$size" =~ ^[0-9]+$ ]] || [ "$size" -lt 5000000000 ]; then
        echo "bench: data-size after load is '${size}' (<5 GB)" >&2
        echo "bench: ClickBench's hits dataset doesn't fit in <5 GB on any" >&2
        echo "bench: system in the catalog; treating this as a partial load" >&2
        echo "bench: (likely an OOM kill mid-COPY)." >&2
        return 1
    fi
}

# Run a single query script and emit a single JSON-array `[t1,t2,t3],` line.
# Per-try timing is also appended to result.csv as `<num>,<try>,<seconds>`.
bench_run_query() {
    local query="$1"
    local query_num="$2"
    local i raw_stderr exit_code timing
    local load_secs=0
    local results=()

    # Cold-cycle: stop, wait until really stopped, drop_caches, start,
    # check. Order matters: the naive order (flush, then stop) leaves
    # mmap-backed engines (Umbra, DuckDB, Hyper, CedarDB) with their
    # data files pinned by the still-running process, so drop_caches
    # can't evict the pages — the new instance then re-mmaps those
    # same files and the "cold" run reads from a warm page cache.
    # Waiting for ./check to fail before flushing makes the cold run
    # actually cold even when ./stop returns before the process is
    # fully gone.
    #
    # BENCH_RESTARTABLE=no skips the stop/wait/start/check dance: those
    # scripts are no-ops for embedded-CLI systems and bench_wait_stopped
    # would otherwise burn its full 60s timeout on every query (./check
    # never starts failing because nothing was actually running).
    if [ "$BENCH_RESTARTABLE" = "yes" ]; then
        ./stop >/dev/null 2>&1 || true
        bench_wait_stopped
        bench_flush_caches
        ./start >/dev/null 2>&1 || true
        bench_check_loop
    else
        bench_flush_caches
    fi

    if [ "$BENCH_DURABLE" != "yes" ]; then
        # In-process server: data lived in process memory and was wiped
        # by the restart above. Re-run ./load so subsequent queries have
        # something to hit, and roll its wall-clock into the first try
        # below — without that, the cold number would be a warm query
        # against a freshly-loaded RAM dataset and not reflect the real
        # cold-from-source cost.
        local load_start load_end
        load_start=$(date +%s.%N)
        ./load >/dev/null 2>&1
        load_end=$(date +%s.%N)
        load_secs=$(awk -v s="$load_start" -v e="$load_end" 'BEGIN{printf "%.6f", e - s}')
    fi

    for i in $(seq 1 "$BENCH_TRIES"); do
        # The query script's contract: stdout = result, stderr's last line =
        # fractional seconds, exit 0 on success.
        raw_stderr=$(printf '%s\n' "$query" | ./query 2>&1 >/dev/null) && exit_code=0 || exit_code=$?

        if [ "$exit_code" -eq 0 ]; then
            # The query script's contract is "fractional seconds on the
            # last line", but several systems (pyspark, JVM-based ones,
            # anything that prints SparkSession shutdown lines after the
            # measurement) emit additional log noise after the timing,
            # so plain `tail -n1` was reading "Stopping SparkContext" or
            # similar and producing all-null result rows. Pull the LAST
            # numeric-looking line instead.
            #
            # Spark also prints its console progress bar with carriage
            # returns instead of newlines:
            #     [Stage 1:>... (0 + 96) / 111]\r\r   spaces   \r{timing}\n
            # so the timing ends up on the same logical line as the
            # progress bar, and the strict ^number$ regex misses it.
            # Translating \r to \n splits those updates into their own
            # lines and the timing stands alone for matching.
            timing=$(printf '%s\n' "$raw_stderr" | tr '\r' '\n' | grep -E '^[0-9]+(\.[0-9]+)?$' | tail -n1)
            [ -z "$timing" ] && timing="null"
        else
            timing="null"
            printf '%s\n' "$raw_stderr" >&2
        fi
        # Cold try (i=1) on a non-durable system: roll the ./load
        # wall-clock into the recorded timing.
        if [ "$i" -eq 1 ] && [ "$BENCH_DURABLE" != "yes" ] && [ "$timing" != "null" ]; then
            timing=$(awk -v t="$timing" -v l="$load_secs" 'BEGIN{printf "%.3f", t + l}')
        fi
        results+=("$timing")
        echo "${query_num},${i},${timing}" >> result.csv
    done

    # Emit "[t1,t2,t3]," for compatibility with the existing log format.
    local out="["
    local j
    for j in "${!results[@]}"; do
        out+="${results[$j]}"
        if [ "$j" -lt $((${#results[@]} - 1)) ]; then
            out+=","
        fi
    done
    out+="],"
    echo "$out"
}

# Concurrent-QPS sustained-throughput test. Runs after the cold/warm sweep
# from a freshly-restarted server (we cold-cycle once more before counting
# so the test doesn't inherit whatever caches the last bench_run_query
# happened to leave). N workers (default 10) each cycle through a
# different permutation of the query index list for D seconds (default
# 600); the permutation depends only on (BENCH_CONCURRENT_SEED,
# connection_id) so two different systems run the same query order on the
# same connection — fair cross-system comparison rather than every
# system rolling a fresh shuffle.
#
# A side watchdog polls ./check every 5 s. If the system dies mid-test the
# watchdog stops+starts it (and ./load for DURABLE=no) without halting the
# workers — they keep firing queries (counting errors against the dead
# server, then successes once it's back). QPS is therefore still the
# honest "successful queries / wall window"; only completely-zero
# successes (e.g. the engine never came back) end up as "null".
#
# Emits two lines that sink.parser pulls into sink.results:
#   Concurrent QPS: <N.NNN>          successful queries / window length
#   Concurrent error ratio: <0.NNN>  errored queries / total attempted
bench_concurrent_qps() {
    local connections="${BENCH_CONCURRENT_CONNECTIONS}"
    local duration="${BENCH_CONCURRENT_DURATION}"
    local seed="${BENCH_CONCURRENT_SEED}"

    # Read the same query file that bench_run_query consumed.
    local queries=() q
    while IFS= read -r q; do
        [ -z "$q" ] && continue
        queries+=("$q")
    done < "$BENCH_QUERIES_FILE"
    local nq=${#queries[@]}

    if [ "$nq" -eq 0 ]; then
        echo "Concurrent QPS: null"
        echo "Concurrent error ratio: null"
        return 0
    fi

    # Fresh restart before the throughput window starts. Mirrors the
    # BENCH_RESTARTABLE handling in bench_run_query.
    if [ "$BENCH_RESTARTABLE" = "yes" ]; then
        ./stop >/dev/null 2>&1 || true
        bench_wait_stopped
        bench_flush_caches
        ./start >/dev/null 2>&1 || true
        bench_check_loop
    else
        bench_flush_caches
    fi
    if [ "$BENCH_DURABLE" != "yes" ]; then
        ./load >/dev/null 2>&1 || true
    fi

    local stats_dir
    stats_dir=$(mktemp -d)
    local deadline=$(($(date +%s) + duration))

    # Watchdog: poll ./check; if the system goes down mid-test, bring it
    # back up without telling the workers. Workers keep firing through
    # the outage — errors during the dead window count toward
    # `Concurrent error ratio`, successes after the revive count toward
    # `Concurrent QPS`. The watchdog's own loop exits when the deadline
    # passes, so `wait` below collects it naturally.
    (
        while [ "$(date +%s)" -lt "$deadline" ]; do
            sleep 5
            if ! ./check >/dev/null 2>&1; then
                ./stop >/dev/null 2>&1 || true
                ./start >/dev/null 2>&1 || true
                local i
                for i in $(seq 1 60); do
                    ./check >/dev/null 2>&1 && break
                    sleep 1
                done
                if [ "$BENCH_DURABLE" != "yes" ]; then
                    ./load >/dev/null 2>&1 || true
                fi
            fi
        done
    ) &

    local c
    for c in $(seq 1 "$connections"); do
        (
            # Deterministic per-connection permutation. The seed combines
            # BENCH_CONCURRENT_SEED with the connection index via SHA-256
            # so cross-version Python hash randomization can't shift it —
            # connection 3 on clickhouse must hit the exact same query
            # order as connection 3 on duckdb for the numbers to be
            # comparable.
            local perm
            mapfile -t perm < <(SEED="$seed" CONN="$c" NQ="$nq" python3 - <<'PY'
import hashlib, os, random
seed_str = f"{os.environ['SEED']}-{os.environ['CONN']}"
seed_int = int.from_bytes(hashlib.sha256(seed_str.encode()).digest()[:8], 'big')
r = random.Random(seed_int)
xs = list(range(int(os.environ['NQ'])))
r.shuffle(xs)
print('\n'.join(map(str, xs)))
PY
)

            local ok=0 err=0 idx=0 qi q_text
            while [ "$(date +%s)" -lt "$deadline" ]; do
                qi="${perm[$idx]}"
                q_text="${queries[$qi]}"
                if printf '%s\n' "$q_text" | ./query >/dev/null 2>&1; then
                    ok=$((ok + 1))
                else
                    err=$((err + 1))
                fi
                idx=$(( (idx + 1) % nq ))
            done
            printf '%s %s\n' "$ok" "$err" > "$stats_dir/$c"
        ) &
    done
    wait

    local total_ok=0 total_err=0 ok err
    for f in "$stats_dir"/*; do
        read -r ok err < "$f"
        total_ok=$((total_ok + ok))
        total_err=$((total_err + err))
    done
    rm -rf "$stats_dir"

    local qps err_ratio
    if [ "$total_ok" -eq 0 ]; then
        # Watchdog never managed to bring the system back up, or no query
        # ever succeeded — record as null per spec.
        qps="null"
    else
        qps=$(awk -v ok="$total_ok" -v d="$duration" 'BEGIN{printf "%.3f", ok/d}')
    fi
    local total=$((total_ok + total_err))
    if [ "$total" -eq 0 ]; then
        err_ratio="null"
    else
        err_ratio=$(awk -v e="$total_err" -v t="$total" 'BEGIN{printf "%.3f", e/t}')
    fi

    echo "Concurrent QPS: $qps"
    echo "Concurrent error ratio: $err_ratio"
}

bench_main() {
    bench_install
    bench_start

    bench_download
    bench_load

    : > result.csv
    local query_num=1
    while IFS= read -r query; do
        # Skip empty lines.
        [ -z "$query" ] && continue
        bench_run_query "$query" "$query_num"
        query_num=$((query_num + 1))
    done < "$BENCH_QUERIES_FILE"

    # data-size may need the server up (e.g. ClickHouse queries system.tables,
    # pandas hits the HTTP server), so report it before stopping.
    echo -n "Data size: "
    ./data-size

    # Sustained-throughput probe under N concurrent connections. Restarts
    # the system internally so the window starts from a known cold state;
    # if the engine dies during the window the side watchdog brings it
    # back up without halting the workers.
    bench_concurrent_qps

    bench_stop || true

    # BENCH_DURABLE=no systems keep hits.parquet around between cold
    # queries so each restart can re-./load it. Tidy up the source data
    # here instead of in the per-system load scripts (which used to do
    # rm -f hits.parquet right after the first load).
    if [ "$BENCH_DURABLE" != "yes" ]; then
        rm -f hits.parquet hits_*.parquet hits.tsv hits.tsv.gz hits.json.gz
        sync
    fi
}

# Only run the full flow when executed directly (or via `exec`). Sourcing the
# file (e.g. for testing individual functions) won't trigger bench_main.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    bench_main
fi
