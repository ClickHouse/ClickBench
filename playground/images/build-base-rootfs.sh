#!/bin/bash
# Build a base Ubuntu 22.04 rootfs for the Firecracker microVMs.
#
# Strategy: start from the official Ubuntu 22.04 cloud image (qcow2), convert
# to raw, mount it, install python3 + sudo + curl + iproute2, drop the agent in
# place, install a systemd unit that runs the agent on boot, and add a
# /etc/fstab line that mounts the dataset disk read-only.
#
# The resulting image is /opt/clickbench-playground/base-rootfs.ext4. Per-system
# images are produced by overlaying the system's ClickBench scripts onto a copy
# of this base.
#
# Idempotent: re-running just re-builds the file from scratch.

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
TMP="${STATE_DIR}/tmp/base-build"
OUT="${STATE_DIR}/base-rootfs.ext4"
# Match the per-system rootfs cap (200 GB) so build-system-rootfs.sh can
# clone the base directly with `cp --sparse=always` and skip resize2fs.
# The image is sparse: mkfs.ext4 with lazy_itable_init writes only the
# superblocks (~50 MB) upfront, and clones inherit that sparseness.
SIZE_GB="${BASE_ROOTFS_SIZE_GB:-200}"
CLOUDIMG_URL="${UBUNTU_CLOUDIMG_URL:-https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT_DIR="${REPO_DIR}/playground/agent"

echo "[base] state=$STATE_DIR out=$OUT size=${SIZE_GB}G"

mkdir -p "$TMP"
mkdir -p "$STATE_DIR/cache"

CLOUDIMG="$STATE_DIR/cache/jammy-cloudimg.img"
if [ ! -f "$CLOUDIMG" ]; then
    echo "[base] downloading cloud image"
    curl -fsSL "$CLOUDIMG_URL" -o "${CLOUDIMG}.part"
    mv "${CLOUDIMG}.part" "$CLOUDIMG"
fi

# Plan: rather than grow the cloud image's partition (which involves
# sfdisk/growpart/resize2fs — all of which call `sync` and therefore stall
# whenever the host is under unrelated writeback pressure), we work in two
# fixed-size hops:
#
#   1. Loop-mount the cloud image's existing partition (2 GB) and use that
#      as a read-only source.
#   2. Create a fresh, no-partition-table ext4 image of SIZE_GB and mount it
#      as the build root. Copy the cloud image's content into it. The new
#      image is what Firecracker boots from (it expects a flat ext4, no
#      partition table).
#
# No growpart, no resize2fs, no waiting on the kernel to flush GBs of
# unrelated dirty pages just to update a partition table.

RAW="$TMP/base.raw"
echo "[base] converting cloud image to raw"
qemu-img convert -O raw "$CLOUDIMG" "$RAW"

SRC_LOOP="$(sudo losetup --find --show --partscan "$RAW")"
trap 'sudo losetup -d "$SRC_LOOP" 2>/dev/null || true' EXIT
for i in $(seq 1 20); do
    if [ -b "${SRC_LOOP}p1" ]; then break; fi
    sleep 0.5
done

SRC_MNT="$TMP/src"
mkdir -p "$SRC_MNT"
sudo mount -o ro "${SRC_LOOP}p1" "$SRC_MNT"

# Now build the *target* image: a plain ext4 file of SIZE_GB with no partition
# table. Firecracker boots root=/dev/vda directly off this.
echo "[base] mkfs.ext4 -> ${SIZE_GB}G no-partition flat image"
FLAT="$TMP/base.flat.ext4"
fallocate -l "${SIZE_GB}G" "$FLAT"
mkfs.ext4 -F -L cbroot -E lazy_itable_init=1,lazy_journal_init=1 "$FLAT" >/dev/null

DST_LOOP="$(sudo losetup --find --show "$FLAT")"
MNT="$TMP/mnt"
mkdir -p "$MNT"
sudo mount "$DST_LOOP" "$MNT"
trap '
    sudo umount "'"$SRC_MNT"'" 2>/dev/null || true
    sudo umount "'"$MNT"'" 2>/dev/null || true
    sudo losetup -d "'"$SRC_LOOP"'" 2>/dev/null || true
    sudo losetup -d "'"$DST_LOOP"'" 2>/dev/null || true
' EXIT

# Stage the cloud image contents into the new rootfs.
echo "[base] copying cloud image content into flat rootfs"
sudo cp -a "$SRC_MNT"/. "$MNT"/
sudo umount "$SRC_MNT"
sudo losetup -d "$SRC_LOOP"
trap '
    sudo umount "'"$MNT"'" 2>/dev/null || true
    sudo losetup -d "'"$DST_LOOP"'" 2>/dev/null || true
' EXIT

# Bind /dev /proc /sys for the chroot. Use `--rbind` so submounts (devpts,
# mqueue, hugepages, /sys/fs/cgroup, …) come along.  Critically, mark each
# new mount `--make-rslave` immediately afterwards. Without that, a later
# `umount -lR` on the chroot's `/dev` propagates back through the shared
# mount group and tears down the *host's* `/dev/pts` — at which point sshd
# can't allocate a PTY and the operator gets locked out.
for d in dev proc sys; do
    sudo mkdir -p "$MNT/$d"
    sudo mount --rbind "/$d" "$MNT/$d"
    sudo mount --make-rslave "$MNT/$d"
done
trap '
    for d in dev proc sys; do sudo umount -lR "'"$MNT"'/$d" 2>/dev/null || true; done
    sudo umount "'"$MNT"'" 2>/dev/null || true
    sudo losetup -d "'"$DST_LOOP"'" 2>/dev/null || true
' EXIT

# Resolve DNS from host inside the chroot. The cloud image ships
# /etc/resolv.conf as a symlink into /run/systemd/resolve/ which is empty
# until systemd-resolved starts; we need a real file for the chroot's apt
# to work.
sudo rm -f "$MNT/etc/resolv.conf"
sudo install -m 0644 /etc/resolv.conf "$MNT/etc/resolv.conf"

# Run system customization inside the chroot.
sudo tee "$MNT/tmp/customize.sh" >/dev/null <<'CUSTOMIZE'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Disable cloud-init's network configuration so eth0 just comes up via
# /etc/network/interfaces-style config we install below.
echo 'network: {config: disabled}' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg

# Keep the image small: turn off heavy services that we don't need on a
# query-serving microVM.
systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
systemctl mask snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
systemctl disable unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 python3-yaml ca-certificates curl wget gnupg sudo less vim-tiny \
    iproute2 iputils-ping net-tools openssh-server lsb-release \
    htop sysstat strace ncdu pigz unzip xz-utils zstd \
    build-essential netbase
apt-get clean
rm -rf /var/lib/apt/lists/*
CUSTOMIZE
sudo chmod +x "$MNT/tmp/customize.sh"
sudo chroot "$MNT" /tmp/customize.sh
sudo rm -f "$MNT/tmp/customize.sh"

# Install Ubuntu's KVM-friendly kernel + its modules INTO the rootfs.
# Firecracker doesn't use grub — we just need /lib/modules/<ver>/ populated
# so the running kernel (Ubuntu generic, extracted from the same .deb) can
# load overlay, veth, br_netfilter, iptable_nat etc. at runtime. Without
# this, the in-VM mounts of /opt/clickbench/system (overlay) and Docker's
# networking (iptables NAT, br_netfilter, veth) silently fail.
sudo cp /var/cache/apt/archives/linux-modules-7.0.0-15-generic_*.deb "$MNT/tmp/"
sudo cp /var/cache/apt/archives/linux-image-7.0.0-15-generic_*.deb "$MNT/tmp/"
sudo tee -a "$MNT/tmp/customize-modules.sh" >/dev/null <<'MODSCRIPT'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
# Extract files from the modules deb without registering it in dpkg.
# `dpkg --unpack` half-installs the package, leaving apt thinking there's
# an unconfigured package with unmet dependencies and refusing subsequent
# `apt-get install`s with "Unmet dependencies. Try 'apt --fix-broken
# install'". Bypass dpkg entirely: dpkg-deb -x just unrolls the data
# tarball into the rootfs.
dpkg-deb -x /tmp/linux-modules-7.0.0-15-generic_*.deb /
# Run depmod so the kernel can find modules by name at runtime.
depmod 7.0.0-15-generic 2>&1 | tail -2 || true
# Pre-load critical modules at boot — Docker needs overlay (storage),
# veth + bridge (per-container netif), br_netfilter (iptables visibility
# across the bridge), iptable_nat + ip_tables + nf_conntrack + nf_nat +
# xt_MASQUERADE (the actual NAT chain for outbound container traffic).
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/clickbench.conf <<EOF
overlay
br_netfilter
veth
iptable_nat
ip_tables
nf_conntrack
nf_nat
xt_MASQUERADE
EOF
rm -f /tmp/linux-modules-*.deb /tmp/linux-image-*.deb
MODSCRIPT
sudo chmod +x "$MNT/tmp/customize-modules.sh"
sudo chroot "$MNT" /tmp/customize-modules.sh
sudo rm -f "$MNT/tmp/customize-modules.sh"

# Re-enter chroot for the rest of customization.
sudo tee "$MNT/tmp/customize-rest.sh" >/dev/null <<'CUSTOMIZE'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Network: parse `ip=GUEST::GATEWAY:NETMASK:::eth0:off` from /proc/cmdline
# at boot and apply it to eth0. Some kernels we run (Ubuntu's generic) lack
# CONFIG_IP_PNP, which makes the kernel's `ip=` boot-arg a no-op and leaves
# eth0 unconfigured at userspace start. Doing the assignment from a tiny
# oneshot service makes us kernel-agnostic — works on the firecracker-ci
# kernel (which does have IP_PNP, so this is just redundant there) and on
# the Ubuntu generic kernel (which doesn't).
systemctl disable systemd-networkd 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

cat > /usr/local/sbin/clickbench-net-up <<'NETUP'
#!/bin/bash
# Apply ip=<vm_ip>::<gw>:<netmask>::eth0:off from /proc/cmdline.
set -e
ip_arg=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^ip=/) print $i}' /proc/cmdline | sed 's/^ip=//')
[ -z "$ip_arg" ] && exit 0
IFS=':' read -r vm_ip _peer gw mask _hostname iface _autoconf <<<"$ip_arg"
iface="${iface:-eth0}"
ip link set "$iface" up
ip addr add "$vm_ip/$(python3 -c "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/$mask').prefixlen)" 2>/dev/null || echo 24)" dev "$iface"
[ -n "$gw" ] && ip route add default via "$gw" || true
NETUP
chmod +x /usr/local/sbin/clickbench-net-up

cat > /etc/systemd/system/clickbench-net.service <<EOF
[Unit]
Description=ClickBench in-VM static network from /proc/cmdline
DefaultDependencies=no
After=systemd-udev-settle.service
Before=network.target shutdown.target
Wants=systemd-udev-settle.service
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/clickbench-net-up
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable clickbench-net.service

# Root has no password; serial console gets autologin. Useful for debugging
# inside the microVM via the Firecracker console socket.
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --keep-baud 115200,38400,9600 %I \$TERM
EOF
passwd -d root

# Replace the entire fstab. The cloud image ships entries for
# `LABEL=cloudimg-rootfs /` and `LABEL=UEFI /boot/efi` — both stale after we
# repack into a fresh ext4 with a different label and no partition table.
# systemd refuses to clear those entries on its own and drops to emergency
# mode when label-based lookups fail. The kernel handles the root mount via
# its `root=/dev/vda` cmdline; we only need fstab for the system disk.
# Three-layer mount plan:
#   1. The shared read-only dataset disk (cbdata) is attached to every VM
#      and mounted at /opt/clickbench/datasets_ro. Holds hits.parquet,
#      hits.tsv, hits.csv, hits_partitioned/*.parquet — same bytes, one
#      copy on the host, never duplicated per VM or per provision.
#   2. The per-VM writable system disk (cbsystem) mounts at
#      /opt/clickbench/sysdisk. We put both the overlay's upperdir AND
#      its workdir inside this mount — overlayfs requires them on the
#      same filesystem; nesting both as subdirs of one mount is the
#      cleanest way.
#         /opt/clickbench/sysdisk/upper/   ClickBench scripts go here
#         /opt/clickbench/sysdisk/work/    overlay scratch (auto-cleared)
#   3. An overlayfs at /opt/clickbench/system merges
#         lowerdir = datasets_ro
#         upperdir = sysdisk/upper
#      The system's load runs at cwd=/opt/clickbench/system and sees a
#      single tree containing scripts + dataset files. When the load
#      does `mv hits.parquet target/` or `chown` on a dataset file,
#      overlayfs copies that one file up from the lower into the upper
#      lazily — only the bytes the script actually mutates land in the
#      per-VM writable layer.
mkdir -p /opt/clickbench/system /opt/clickbench/datasets_ro \
         /opt/clickbench/sysdisk /opt/clickbench/lib

# Stub download-hits-* scripts. ClickBench's real download-hits-* fetch
# the dataset from datasets.clickhouse.com; in the playground we already
# have the data RO-mounted at /opt/clickbench/datasets_ro, so produce
# symlinks instead. The interface (optional target-dir argument) matches
# lib/download-hits-* so per-system scripts that do
# `../lib/download-hits-... <somewhere>` work unchanged. Symlinks instead
# of copies save 14-75 GB of in-VM writes per system.
cat > /opt/clickbench/lib/download-hits-parquet-single <<'EOF'
#!/bin/bash
set -e
dir="${1:-.}"; mkdir -p "$dir"; cd "$dir"
ln -sf /opt/clickbench/datasets_ro/hits.parquet hits.parquet
EOF
cat > /opt/clickbench/lib/download-hits-parquet-partitioned <<'EOF'
#!/bin/bash
set -e
dir="${1:-.}"; mkdir -p "$dir"; cd "$dir"
for i in $(seq 0 99); do
    ln -sf "/opt/clickbench/datasets_ro/hits_${i}.parquet" "hits_${i}.parquet"
done
EOF
cat > /opt/clickbench/lib/download-hits-tsv <<'EOF'
#!/bin/bash
set -e
dir="${1:-.}"; mkdir -p "$dir"; cd "$dir"
ln -sf /opt/clickbench/datasets_ro/hits.tsv hits.tsv
EOF
cat > /opt/clickbench/lib/download-hits-csv <<'EOF'
#!/bin/bash
set -e
dir="${1:-.}"; mkdir -p "$dir"; cd "$dir"
ln -sf /opt/clickbench/datasets_ro/hits.csv hits.csv
EOF
chmod +x /opt/clickbench/lib/download-hits-*
cat > /etc/fstab <<EOF
LABEL=cbdata    /opt/clickbench/datasets_ro   ext4      ro,nofail,noatime,nodev,nosuid                                                            0 0
LABEL=cbsystem  /opt/clickbench/sysdisk       ext4      rw,nofail,noatime                                                                         0 0
overlay         /opt/clickbench/system        overlay   nofail,lowerdir=/opt/clickbench/datasets_ro,upperdir=/opt/clickbench/sysdisk/upper,workdir=/opt/clickbench/sysdisk/work,x-systemd.requires-mounts-for=/opt/clickbench/sysdisk,x-systemd.requires-mounts-for=/opt/clickbench/datasets_ro 0 0
EOF

# Make sure the home dir exists; some installers (vcpkg, gizmosql) honor $HOME
# and break on empty.
mkdir -p /root
chmod 700 /root

# /etc/hosts: ensure both "localhost" and the cloud-image hostname "ubuntu"
# resolve locally. Without the second entry, every sudo invocation does a
# reverse DNS lookup that times out (~2 s each) trying to find "ubuntu" on
# the dropped-internet network, which adds up to a multi-second floor on
# every /query. Pre-stamping the host name removes the round trip.
cat > /etc/hosts <<EOF
127.0.0.1   localhost ubuntu
::1         localhost ip6-localhost ip6-loopback
EOF
CUSTOMIZE
sudo chmod +x "$MNT/tmp/customize-rest.sh"
sudo chroot "$MNT" /tmp/customize-rest.sh
sudo rm -f "$MNT/tmp/customize-rest.sh"

# Install the agent payload + systemd unit.
sudo mkdir -p "$MNT/opt/clickbench-agent"
sudo cp "$AGENT_DIR/agent.py" "$MNT/opt/clickbench-agent/agent.py"
sudo chmod +x "$MNT/opt/clickbench-agent/agent.py"
sudo cp "$AGENT_DIR/clickbench-agent.service" "$MNT/etc/systemd/system/clickbench-agent.service"
sudo chroot "$MNT" systemctl enable clickbench-agent.service

# Unmount and detach. The flat ext4 in $FLAT IS the target; just move it to
# $OUT and we're done. Skip the partitioned -> flat re-copy step.
sudo umount -lR "$MNT/dev" "$MNT/proc" "$MNT/sys"
sudo umount "$MNT"
sudo losetup -d "$DST_LOOP"
trap - EXIT

mv "$FLAT" "$OUT"
rm -rf "$TMP"

# Final fsck: every per-system rootfs is cloned from this file and then
# resize2fs'd, which requires the source filesystem to be clean. Doing
# the fsck once here, while build-base-rootfs.sh has full I/O headroom,
# is much cheaper than doing it 98 times during the parallel system
# build phase.
sudo e2fsck -fy "$OUT" >/dev/null 2>&1 || true

echo "[base] done: $OUT ($(du -h "$OUT" | cut -f1) physical, $(du -h --apparent-size "$OUT" | cut -f1) apparent)"
