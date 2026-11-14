#!/bin/bash
# Run the full ClickBench benchmark on MotherDuck once per Duckling (compute)
# size, capturing each run's output to motherduck-<size>.log.
#
#   motherduck_token=<TOKEN> ./run-all-sizes.sh [size ...]
#
# Runs always proceed largest size first. With no size arguments the default
# set is, largest first:
#   mega jumbo standard pulse
# giga is excluded by default because some trial accounts don't have it enabled;
# opt in with INCLUDE_GIGA=1 or by naming giga explicitly as an argument.
#
# Between runs it calls ./set-instance-size to change the account's read_write
# Duckling size and waits (including a >=2 min stabilization margin) for the
# change to go live. Each run reloads the data (load time is itself a per-size
# metric) and runs all 43 queries plus, if enabled, the concurrent-QPS test.
#
# Env:
#   motherduck_token / MOTHERDUCK_TOKEN   required (same PAT used for md:)
#   motherduck_username                   optional; auto-discovered via SQL
#   INCLUDE_GIGA                          set to also run giga in the default set
#   RESTORE_SIZE                          optional size to restore when done
set -eu
cd "$(dirname "$0")"

export motherduck_token="${motherduck_token:-${MOTHERDUCK_TOKEN:-}}"
: "${motherduck_token:?motherduck_token is required}"

# One date for the whole sweep, so every size lands under results/<date>/.
RUN_DATE=$(date +%F)

# Canonical order, largest first. Runs proceed in this order no matter how the
# sizes are specified.
all_largest_first=(giga mega jumbo standard pulse)

if [ "$#" -gt 0 ]; then
    requested=("$@")
else
    requested=(mega jumbo standard pulse)
    [ -n "${INCLUDE_GIGA:-}" ] && requested=(giga "${requested[@]}")
fi

# Validate the requested sizes, then order them largest-first (dedup included).
for s in "${requested[@]}"; do
    case " ${all_largest_first[*]} " in
        *" $s "*) ;;
        *) echo "unknown size: $s (valid: ${all_largest_first[*]})" >&2; exit 2 ;;
    esac
done
sizes=()
for s in "${all_largest_first[@]}"; do
    for r in "${requested[@]}"; do
        [ "$s" = "$r" ] && { sizes+=("$s"); break; }
    done
done

# Install the client (python + duckdb) once up front so set-instance-size can
# poll md_live_duckling_size() before the first run's own install step.
./install

summary=()
for size in "${sizes[@]}"; do
    echo "============================================================"
    echo "=== MotherDuck size: $size"
    echo "============================================================"
    # A size the account can't use (e.g. mega/giga on a trial plan) shouldn't
    # kill the whole sweep — log it and move on.
    if ! ./set-instance-size "$size"; then
        echo "  set-instance-size failed for $size (size unavailable on this account?); skipping"
        summary+=("$size: SKIPPED (set-instance-size failed)")
        continue
    fi

    log="motherduck-${size}.log"
    # Record the size for downstream labeling (the shared cloud-init only logs
    # the client EC2 type as "machine"), then run the benchmark.
    if {
        echo "MotherDuck duckling size: $size"
        ./benchmark.sh
    } > "$log" 2>&1; then
        echo "  -> $log"
        # Emit a committable results JSON labeled by Duckling size.
        if json=$(./make-result "$size" "$log" "$RUN_DATE"); then
            echo "  -> $json"
            summary+=("$size: $log, $json")
        else
            echo "  (could not generate results JSON for $size)"
            summary+=("$size: $log")
        fi
    else
        echo "  benchmark.sh exited non-zero for $size; see $log"
        summary+=("$size: $log (benchmark error)")
    fi
done

if [ -n "${RESTORE_SIZE:-}" ]; then
    echo "=== restoring size to $RESTORE_SIZE"
    ./set-instance-size "$RESTORE_SIZE"
fi

echo "============================================================"
echo "Done. Per-size logs:"
for s in "${summary[@]}"; do echo "  $s"; done
