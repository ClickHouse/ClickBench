#!/bin/bash
# Idempotent: download firecracker + jailer if they're not in
# /opt/clickbench-playground/bin/, and fetch the guest kernel.

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
FC_VERSION="${FIRECRACKER_VERSION:-v1.13.1}"
KERNEL_URL="${GUEST_KERNEL_URL:-https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.13/x86_64/vmlinux-6.1.141}"

sudo mkdir -p "$STATE_DIR"/{bin,kernel,datasets,systems,vms,logs,run,snapshots,tmp,cache}
# Only chown the top-level subdirs we created. `chown -R` on $STATE_DIR
# would descend into any live mount underneath it — notably the loop-
# mounted rootfs that build-base-rootfs.sh keeps open under tmp/base-build
# while it's running — and flip /etc/sudoers inside the future VM image
# to uid 1000, breaking sudo on every subsequent provision.
sudo chown "$(id -u):$(id -g)" \
    "$STATE_DIR" \
    "$STATE_DIR"/{bin,kernel,datasets,systems,vms,logs,run,snapshots,tmp,cache}

# The playground relies on reflink (cp --reflink=always) to clone
# 200 GB-apparent / multi-GB-real per-VM disks in milliseconds instead
# of seconds. ext4 ships reflink support behind the `shared_blocks`
# feature flag, but mke2fs in Ubuntu 22.04 / 24.04 doesn't expose it
# yet — so we format the playground volume as XFS, which has reflink
# enabled by default since mkfs.xfs 4.18 (2018). If you're staging the
# host yourself, set this up before running install-firecracker.sh:
#
#   sudo mkfs.xfs -L cbplayground -f /dev/<your-device>
#   echo 'LABEL=cbplayground /opt/clickbench-playground xfs \
#       defaults,noatime,discard,nofail 0 2' | sudo tee -a /etc/fstab
#   sudo mount /opt/clickbench-playground
#
# Sanity-check at install time so a missing reflink is loud:
if ! ( cd "$STATE_DIR" && tmp1="$(mktemp -p .)" && \
       tmp2="$(mktemp -p . -u)" && \
       cp --reflink=always "$tmp1" "$tmp2" 2>/dev/null; rc=$? ; \
       rm -f "$tmp1" "$tmp2"; exit "$rc" ); then
    echo "[install] ERROR: $STATE_DIR does not support reflink. The" >&2
    echo "playground needs cp --reflink=always to clone per-VM disks" >&2
    echo "fast. Reformat the volume as XFS (or ext4 with shared_blocks)" >&2
    echo "and re-run this script. See the comment block above." >&2
    exit 1
fi

if [ ! -x "$STATE_DIR/bin/firecracker" ]; then
    arch="$(uname -m)"
    url="https://github.com/firecracker-microvm/firecracker/releases/download/${FC_VERSION}/firecracker-${FC_VERSION}-${arch}.tgz"
    echo "[install] firecracker ${FC_VERSION}"
    tmpdir="$(mktemp -d)"
    curl -fsSL "$url" -o "$tmpdir/firecracker.tgz"
    tar -C "$tmpdir" -xzf "$tmpdir/firecracker.tgz" --strip-components=1
    install -m 0755 "$tmpdir/firecracker-${FC_VERSION}-${arch}" "$STATE_DIR/bin/firecracker"
    install -m 0755 "$tmpdir/jailer-${FC_VERSION}-${arch}"      "$STATE_DIR/bin/jailer"
    rm -rf "$tmpdir"
fi

if [ ! -f "$STATE_DIR/kernel/vmlinux" ]; then
    echo "[install] guest kernel"
    curl -fsSL "$KERNEL_URL" -o "$STATE_DIR/kernel/vmlinux"
fi

# IP forwarding for the per-VM TAPs.
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-clickbench-playground.conf >/dev/null

# Datalake-style systems run with restricted outbound: the playground
# server hosts an SNI-allowlist proxy (playground/server/sni_proxy.py)
# bound on 0.0.0.0:8443 / :8080, and iptables REDIRECTs the VM TAP's
# 443/80 to those ports (see playground/server/net.enable_filtered_internet).
# Make sure local Linux conntrack can route the REDIRECT and the
# proxy's outbound connection back to the VM. Nothing else to install
# — the proxy is pure Python, the kernel needs route_localnet so
# REDIRECT can target a localhost listener from a non-local source.
sudo sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null
echo "net.ipv4.conf.all.route_localnet=1" | sudo tee -a /etc/sysctl.d/99-clickbench-playground.conf >/dev/null

echo "[install] done"
"$STATE_DIR/bin/firecracker" --version
