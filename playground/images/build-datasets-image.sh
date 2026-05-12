#!/bin/bash
# Bundle the downloaded datasets directory into a single read-only ext4 image
# (datasets.ext4) that gets attached to every Firecracker VM as a virtio-blk
# device. Mounted at /opt/clickbench/datasets in the guest.
#
# A single shared read-only image is much more efficient than virtio-fs (which
# Firecracker doesn't ship) or per-VM copies of a ~250 GB dataset.

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
SRC="$STATE_DIR/datasets"
OUT="$STATE_DIR/datasets.ext4"

if [ ! -d "$SRC" ]; then
    echo "no datasets dir: $SRC" >&2
    exit 1
fi

bytes=$(du -sb "$SRC" | awk '{print $1}')
overhead=$(( 4 * 1024 * 1024 * 1024 ))  # 4 GiB headroom for ext4 metadata
size=$(( bytes + overhead ))
# Round up to MiB
size_mib=$(( (size + 1024*1024 - 1) / (1024*1024) ))

echo "[datasets] payload=$bytes B  image=$size_mib MiB  out=$OUT"

rm -f "$OUT"
truncate -s "${size_mib}M" "$OUT"
mkfs.ext4 -F -L cbdata -m 0 -E lazy_itable_init=1,lazy_journal_init=1 -O ^has_journal "$OUT" >/dev/null

MNT="$(mktemp -d)"
trap 'sudo umount "'"$MNT"'" 2>/dev/null || true; rmdir "'"$MNT"'" 2>/dev/null || true' EXIT
sudo mount -o loop "$OUT" "$MNT"
sudo rsync -a --info=progress2 "$SRC"/. "$MNT"/
sudo sync
sudo umount "$MNT"
trap - EXIT

echo "[datasets] done"
ls -lh "$OUT"
