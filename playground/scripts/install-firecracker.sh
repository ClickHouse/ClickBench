#!/bin/bash
# Idempotent: download firecracker + jailer if they're not in
# /opt/clickbench-playground/bin/, and fetch the guest kernel.

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
FC_VERSION="${FIRECRACKER_VERSION:-v1.13.1}"
KERNEL_URL="${GUEST_KERNEL_URL:-https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.13/x86_64/vmlinux-6.1.141}"

sudo mkdir -p "$STATE_DIR"/{bin,kernel,datasets,systems,vms,logs,run,snapshots,tmp,cache}
sudo chown -R "$(id -u):$(id -g)" "$STATE_DIR"

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

echo "[install] done"
"$STATE_DIR/bin/firecracker" --version
