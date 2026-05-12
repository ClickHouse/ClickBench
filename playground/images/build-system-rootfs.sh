#!/bin/bash
# Build a per-system rootfs and "system disk" image for Firecracker.
#
# Outputs (under /opt/clickbench-playground/systems/<name>/):
#   rootfs.ext4         CoW-ish copy of base-rootfs.ext4 (sparse 200 GB)
#   system.ext4         ext4 holding ClickBench scripts + the dataset files
#                       this system needs. Mounted RW at /opt/clickbench/system
#                       in the VM. We include the data here (not a separate
#                       read-only datasets disk) because many load scripts do
#                       `sudo chown` on the source files, and chown follows
#                       symlinks — i.e. it tries to mutate the RO-mounted
#                       dataset and fails. Putting the data on the RW system
#                       disk sidesteps the problem entirely.
#
# The disk is sized based on the system's data format:
#   parquet, parquet-partitioned    16 GB
#   tsv, csv                        88 GB
#   none/unknown                     2 GB
#
# Usage:  build-system-rootfs.sh <system-name>

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <system-name>" >&2
    exit 2
fi
SYSTEM="$1"

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="$STATE_DIR/base-rootfs.ext4"
DATASETS="$STATE_DIR/datasets"
SRC="$REPO_DIR/$SYSTEM"
OUT_DIR="$STATE_DIR/systems/$SYSTEM"
ROOTFS="$OUT_DIR/rootfs.ext4"
SYSDISK="$OUT_DIR/system.ext4"

ROOTFS_SIZE_GB="${VM_ROOTFS_SIZE_GB:-200}"

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

# Discover the data format from the system's benchmark.sh. Source the file in
# a noop-shell so any of `export BENCH_DOWNLOAD_SCRIPT="..."` /
# `BENCH_DOWNLOAD_SCRIPT=...` etc. just becomes a variable. Drop everything
# else by running in a subshell.
download_script="$(set +e; unset BENCH_DOWNLOAD_SCRIPT; \
    eval "$(grep -E '^[[:space:]]*(export[[:space:]]+)?BENCH_DOWNLOAD_SCRIPT=' "$SRC/benchmark.sh" | head -1)"; \
    printf '%s' "${BENCH_DOWNLOAD_SCRIPT:-}")"
case "$download_script" in
    *parquet-partitioned*)  format=parquet-partitioned; sysdisk_size_gb=16 ;;
    *parquet-single*)       format=parquet;             sysdisk_size_gb=16 ;;
    *tsv*)                  format=tsv;                 sysdisk_size_gb=88 ;;
    *csv*)                  format=csv;                 sysdisk_size_gb=88 ;;
    "")                     format=none;                sysdisk_size_gb=2  ;;
    *)                      format=unknown;             sysdisk_size_gb=4  ;;
esac
echo "[sys:$SYSTEM] format=$format sysdisk_size=${sysdisk_size_gb}G"

mkdir -p "$OUT_DIR"

# 1. Rootfs as a sparse file. Allocate 200 GB but only write blocks when
# something inside the VM dirties them.
echo "[sys:$SYSTEM] rootfs.ext4 ${ROOTFS_SIZE_GB}G (sparse)"
rm -f "$ROOTFS"
truncate -s "${ROOTFS_SIZE_GB}G" "$ROOTFS"
mkfs.ext4 -F -L cbroot -E lazy_itable_init=1,lazy_journal_init=1 "$ROOTFS" >/dev/null

BASE_MNT="$(mktemp -d)"
DST_MNT="$(mktemp -d)"
trap '
    sudo umount "'"$BASE_MNT"'" 2>/dev/null || true
    sudo umount "'"$DST_MNT"'" 2>/dev/null || true
    rmdir "'"$BASE_MNT"'" "'"$DST_MNT"'" 2>/dev/null || true
' EXIT
# A prior smoke-boot likely left the base rootfs's journal dirty. Replay it
# (fsck -fy is idempotent) before opening read-only — otherwise the loop
# mount refuses with "cannot mount read-only" and the script blows up
# silently.
sudo e2fsck -fy "$BASE" >/dev/null 2>&1 || true
sudo mount -o loop,ro "$BASE" "$BASE_MNT"
sudo mount -o loop "$ROOTFS" "$DST_MNT"
sudo cp -a --reflink=auto "$BASE_MNT"/. "$DST_MNT"/
echo "$SYSTEM" | sudo tee "$DST_MNT/etc/clickbench-system" >/dev/null
sudo sync
sudo umount "$DST_MNT"
sudo umount "$BASE_MNT"
trap - EXIT

# 2. System disk: ClickBench scripts + the data files this system needs.
# Sized per-format. The agent runs ./install/./start/./load with cwd here, so
# the load script's relative references to hits.parquet / hits.tsv / etc. all
# resolve to local files it owns.
echo "[sys:$SYSTEM] system.ext4 ${sysdisk_size_gb}G"
rm -f "$SYSDISK"
truncate -s "${sysdisk_size_gb}G" "$SYSDISK"
mkfs.ext4 -F -L cbsystem -E lazy_itable_init=1,lazy_journal_init=1 "$SYSDISK" >/dev/null

SYS_MNT="$(mktemp -d)"
trap 'sudo umount "'"$SYS_MNT"'" 2>/dev/null || true; rmdir "'"$SYS_MNT"'" 2>/dev/null || true' EXIT
sudo mount -o loop "$SYSDISK" "$SYS_MNT"

# Scripts.
sudo rsync -a --exclude 'results/' --exclude '*.json' --exclude 'README*' \
    "$SRC"/ "$SYS_MNT"/

# Some systems' scripts use ../lib/... — provide it.
sudo mkdir -p "$SYS_MNT/_lib"
sudo cp -a "$REPO_DIR/lib"/. "$SYS_MNT/_lib"/

# Data files.
case "$format" in
    parquet)
        if [ -f "$DATASETS/hits.parquet" ]; then
            echo "[sys:$SYSTEM] copying hits.parquet"
            sudo cp --reflink=auto "$DATASETS/hits.parquet" "$SYS_MNT/hits.parquet"
        else
            echo "[sys:$SYSTEM] WARN hits.parquet not present in datasets dir"
        fi
        ;;
    parquet-partitioned)
        if [ -d "$DATASETS/hits_partitioned" ]; then
            echo "[sys:$SYSTEM] copying 100 partitioned parquet files"
            sudo cp --reflink=auto "$DATASETS/hits_partitioned"/hits_*.parquet "$SYS_MNT/"
        else
            echo "[sys:$SYSTEM] WARN hits_partitioned/ not present"
        fi
        ;;
    tsv)
        if [ -f "$DATASETS/hits.tsv" ]; then
            echo "[sys:$SYSTEM] copying hits.tsv (large)"
            sudo cp --reflink=auto "$DATASETS/hits.tsv" "$SYS_MNT/hits.tsv"
        else
            echo "[sys:$SYSTEM] WARN hits.tsv not present"
        fi
        ;;
    csv)
        if [ -f "$DATASETS/hits.csv" ]; then
            echo "[sys:$SYSTEM] copying hits.csv (large)"
            sudo cp --reflink=auto "$DATASETS/hits.csv" "$SYS_MNT/hits.csv"
        else
            echo "[sys:$SYSTEM] WARN hits.csv not present"
        fi
        ;;
    none|unknown)
        echo "[sys:$SYSTEM] no data staging for format=$format"
        ;;
esac

sudo chown -R 0:0 "$SYS_MNT"
sudo chmod -R u+rwX,go+rX "$SYS_MNT"
sudo sync
sudo umount "$SYS_MNT"
trap - EXIT

echo "[sys:$SYSTEM] done"
ls -lh "$OUT_DIR"
