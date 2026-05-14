#!/bin/bash
# Walk every per-system directory under /opt/clickbench-playground/systems/
# and convert any uncompressed golden (rootfs.golden.ext4, system.golden.ext4,
# swap.golden.raw) into its .zst counterpart. Skips systems that already
# have a .zst alongside (or instead of) the raw file.
#
# Compresses one system at a time, but uses all CPU cores per system.
# Safe to Ctrl-C: zstd writes to <name>.zst.tmp first and we only unlink
# the original after the rename. (If you find a `.zst.tmp` left behind
# from an interrupted run, delete it before re-running.)
set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
SYSTEMS_DIR="$STATE_DIR/systems"

compress_one() {
    local src="$1"
    local zst="${src}.zst"
    local tmp="${src}.zst.tmp"
    if [ -f "$zst" ]; then
        echo "    [skip] $zst exists"
        return
    fi
    if [ ! -f "$src" ]; then
        return
    fi
    local before
    before=$(du -B 1 "$src" | awk '{print $1}')
    echo "    [compress] $src ($(numfmt --to=iec-i --suffix=B "$before"))"
    sudo zstd -1 -T0 --sparse --quiet -o "$tmp" "$src"
    sudo mv "$tmp" "$zst"
    sudo rm -f "$src"
    local after
    after=$(du -B 1 "$zst" | awk '{print $1}')
    echo "    [done]     $zst ($(numfmt --to=iec-i --suffix=B "$after"))"
}

free_gb() { df -BG --output=avail "$STATE_DIR" | tail -1 | tr -dc '0-9'; }

echo "free before: $(free_gb) GiB"
for d in "$SYSTEMS_DIR"/*/; do
    sys="$(basename "$d")"
    echo "=== $sys ==="
    for name in rootfs.golden.ext4 system.golden.ext4 swap.golden.raw; do
        compress_one "$d$name"
    done
done
echo "free after:  $(free_gb) GiB"
