#!/bin/bash
# Build a per-system rootfs and "system disk" image for Firecracker.
#
# Outputs (under /opt/clickbench-playground/systems/<name>/):
#   rootfs.ext4         CoW-ish copy of base-rootfs.ext4 (sparse 200 GB)
#   system.ext4         ~2 GB ext4 holding ONLY the system's ClickBench
#                       scripts. The dataset is *not* copied in here — it
#                       comes from the host-side shared datasets.ext4
#                       attached read-only to every VM (build-datasets-
#                       image.sh). The agent's /provision step copies
#                       only the bytes the load script actually needs.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <system-name>" >&2
    exit 2
fi
SYSTEM="$1"

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$STATE_DIR/base-rootfs.ext4"
SRC="$REPO_DIR/$SYSTEM"
OUT_DIR="$STATE_DIR/systems/$SYSTEM"
ROOTFS="$OUT_DIR/rootfs.ext4"
SYSDISK="$OUT_DIR/system.ext4"

ROOTFS_SIZE_GB="${VM_ROOTFS_SIZE_GB:-200}"
# Apparent size of the cbsystem disk. Every byte the load script writes
# (overlay copy-ups of the dataset, the database's own files —
# MergeTree parts, duckdb's hits.db, etc.) lands here. Some systems are
# heavy: tidb writes ~137 GB, postgres-indexed ~80 GB, druid ~50 GB.
# Match the rootfs cap (200 GB) so any single system has room.
#
# This is a SPARSE file: `truncate` reserves the apparent size but
# allocates no physical blocks. mkfs.ext4 only writes the small initial
# metadata. Real disk usage tracks the bytes the VM actually writes,
# and `cp --sparse=always` on the golden-disk path preserves that
# sparseness through snapshot+restore — snapshots of light systems
# stay light.
SYSDISK_SIZE_GB="${VM_SYSDISK_SIZE_GB:-200}"

if [ ! -f "$BASE" ]; then
    echo "base rootfs not found: $BASE — run build-base-rootfs.sh first" >&2
    exit 1
fi
if [ ! -d "$SRC" ]; then
    echo "no such system directory: $SRC" >&2
    exit 1
fi
for f in install start load query check stop; do
    if [ ! -x "$SRC/$f" ]; then
        echo "system '$SYSTEM' missing executable $f — not playground-ready" >&2
        exit 1
    fi
done

mkdir -p "$OUT_DIR"

# 1. Rootfs: clone the base ext4 file block-level (sparse). The base is
# already sized at ROOTFS_SIZE_GB with mostly-empty ext4 metadata, so
# `cp --sparse=always` produces a sparse 200 GB image of the right size
# in seconds — no resize2fs, no e2fsck, no mount-and-rsync.
echo "[sys:$SYSTEM] rootfs.ext4 (sparse clone of base)"
rm -f "$ROOTFS"
cp --sparse=always "$BASE" "$ROOTFS"

# Stamp the system name so the agent can identify itself.
# Note: no explicit `sync` — `umount` syncs the filesystem being unmounted.
# A global `sync` here would block until every dirty page on the host's
# disk is flushed, which under 98-way parallel builds means every build
# waits for everyone else's writeback before its own umount returns.
MNT="$(mktemp -d)"
trap 'sudo umount "'"$MNT"'" 2>/dev/null || true; rmdir "'"$MNT"'" 2>/dev/null || true' EXIT
sudo mount -o loop "$ROOTFS" "$MNT"
echo "$SYSTEM" | sudo tee "$MNT/etc/clickbench-system" >/dev/null
sudo umount "$MNT"
trap - EXIT

# 2. System disk: ClickBench scripts only. Sized at SYSDISK_SIZE_GB (2 GB
# default). The agent populates the dataset files into this disk at
# provision time by copying from the shared read-only datasets disk.
echo "[sys:$SYSTEM] system.ext4 ${SYSDISK_SIZE_GB}G"
rm -f "$SYSDISK"
truncate -s "${SYSDISK_SIZE_GB}G" "$SYSDISK"
mkfs.ext4 -F -L cbsystem -E lazy_itable_init=1,lazy_journal_init=1 "$SYSDISK" >/dev/null

SYS_MNT="$(mktemp -d)"
trap 'sudo umount "'"$SYS_MNT"'" 2>/dev/null || true; rmdir "'"$SYS_MNT"'" 2>/dev/null || true' EXIT
sudo mount -o loop "$SYSDISK" "$SYS_MNT"

# The cbsystem disk is mounted at /opt/clickbench/sysdisk in the guest;
# the overlay points its upperdir at sysdisk/upper and its workdir at
# sysdisk/work. Pre-create that layout and drop the system's ClickBench
# scripts into upper.
sudo mkdir -p "$SYS_MNT/upper" "$SYS_MNT/work"
sudo rsync -a --exclude 'results/' --exclude '*.json' --exclude 'README*' \
    "$SRC"/ "$SYS_MNT/upper"/

# Some systems' scripts use ../lib/... — make it visible.
sudo mkdir -p "$SYS_MNT/upper/_lib"
sudo cp -a "$REPO_DIR/lib"/. "$SYS_MNT/upper/_lib"/

# Discover the data format from benchmark.sh and stamp it in the upper;
# the agent uses this to decide which dataset symlinks to add for
# partitioned formats.
download_script="$(set +e; unset BENCH_DOWNLOAD_SCRIPT; \
    eval "$(grep -E '^[[:space:]]*(export[[:space:]]+)?BENCH_DOWNLOAD_SCRIPT=' "$SRC/benchmark.sh" | head -1)"; \
    printf '%s' "${BENCH_DOWNLOAD_SCRIPT:-}")"
case "$download_script" in
    *parquet-partitioned*)  format=parquet-partitioned ;;
    *parquet-single*)       format=parquet             ;;
    *tsv*)                  format=tsv                 ;;
    *csv*)                  format=csv                 ;;
    "")                     format=none                ;;
    *)                      format=unknown             ;;
esac
echo "$format" | sudo tee "$SYS_MNT/upper/.data-format" >/dev/null
echo "[sys:$SYSTEM] format=$format"

sudo chown -R 0:0 "$SYS_MNT/upper"
sudo chmod -R u+rwX,go+rX "$SYS_MNT/upper"
sudo umount "$SYS_MNT"
trap - EXIT

echo "[sys:$SYSTEM] done"
ls -lh "$OUT_DIR"
