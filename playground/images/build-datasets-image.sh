#!/bin/bash
# Build a single read-only ext4 image of /opt/clickbench-playground/datasets,
# attached as virtio-blk to every per-system VM. This replaces the previous
# scheme of copying the dataset into each per-system disk: one image on the
# host vs N copies saves ~1-2 TB across the catalog.
#
# The VM-side fstab line (LABEL=cbdata ... ro) is provisioned by
# build-base-rootfs.sh; the agent copies the needed files into the writable
# system disk at provision time so load scripts that mv/chown can do so on
# files they own.

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
SRC="$STATE_DIR/datasets"
OUT="$STATE_DIR/datasets.ext4"

if [ ! -d "$SRC" ]; then
    echo "no datasets dir: $SRC" >&2
    exit 1
fi

bytes=$(du -sb "$SRC" | awk '{print $1}')
# Add 8 GB headroom for ext4 metadata + ext4 mkfs reserved blocks.
overhead=$(( 8 * 1024 * 1024 * 1024 ))
size_mib=$(( (bytes + overhead + 1024*1024 - 1) / (1024*1024) ))

echo "[datasets] payload=$bytes B  image=${size_mib} MiB"

# Idempotency: skip the rebuild if a present image is at least as large as
# the source and was modified after the most-recent source file. The image
# never holds anything but the dataset, so a same-or-larger size + a
# fresher mtime is sufficient evidence that the contents are current.
# Force-rebuild with REBUILD=1 to override.
if [ -f "$OUT" ] && [ "${REBUILD:-}" != "1" ]; then
    out_size=$(stat -c%s "$OUT" 2>/dev/null || echo 0)
    out_mtime=$(stat -c%Y "$OUT" 2>/dev/null || echo 0)
    src_newest=$(find "$SRC" -type f -printf '%T@\n' | sort -rn | head -1 | cut -d. -f1)
    if [ "$out_size" -ge "$bytes" ] && [ "$out_mtime" -gt "${src_newest:-0}" ]; then
        echo "[datasets] cached ($(du -h "$OUT" | cut -f1)); set REBUILD=1 to force"
        ls -lh "$OUT"
        exit 0
    fi
fi

rm -f "$OUT"
truncate -s "${size_mib}M" "$OUT"
# Disable the journal (-O ^has_journal) and reserve 0 blocks for root
# (-m 0); both make sense for a read-only image.
mkfs.ext4 -F -L cbdata -m 0 -O ^has_journal \
    -E lazy_itable_init=1,lazy_journal_init=1 "$OUT" >/dev/null

MNT="$(mktemp -d)"
trap 'sudo umount "'"$MNT"'" 2>/dev/null || true; rmdir "'"$MNT"'" 2>/dev/null || true' EXIT
sudo mount -o loop "$OUT" "$MNT"
sudo rsync -a "$SRC"/. "$MNT"/
sudo umount "$MNT"
trap - EXIT

# Mark the image read-only on the host too, so a misconfigured drive (RW
# attach by mistake) can't scribble.
chmod a-w "$OUT"

echo "[datasets] done"
ls -lh "$OUT"
