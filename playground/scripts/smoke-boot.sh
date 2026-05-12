#!/bin/bash
# Boot a single Firecracker VM with the playground's base rootfs, attaching
# only the rootfs (no system disk, no dataset disk). Confirms the kernel +
# rootfs + agent path works end-to-end before we start asking it to install
# a database. Tears down on exit.
#
# Usage: smoke-boot.sh [slot]
# Logs go to /opt/clickbench-playground/logs/smoke-boot.log

set -euo pipefail

STATE_DIR="${PLAYGROUND_STATE_DIR:-/opt/clickbench-playground}"
SLOT="${1:-250}"  # high slot to avoid clashing with the real registry
SOCK="$STATE_DIR/vms/smoke-boot.sock"
LOG="$STATE_DIR/logs/smoke-boot.log"
TAP="fc-tap-${SLOT}"
HOST_IP="10.200.${SLOT}.1"
GUEST_IP="10.200.${SLOT}.2"

cleanup() {
    echo "[smoke] cleanup"
    pkill -f "firecracker.*${SOCK}" 2>/dev/null || true
    sleep 0.3
    sudo ip link set "$TAP" down 2>/dev/null || true
    sudo ip tuntap del dev "$TAP" mode tap 2>/dev/null || true
    rm -f "$SOCK"
}
trap cleanup EXIT

mkdir -p "$STATE_DIR/vms" "$STATE_DIR/logs"
rm -f "$SOCK"

if ! ip link show "$TAP" >/dev/null 2>&1; then
    sudo ip tuntap add dev "$TAP" mode tap
fi
sudo ip addr flush dev "$TAP" 2>/dev/null || true
sudo ip addr add "${HOST_IP}/24" dev "$TAP"
sudo ip link set "$TAP" up

# Start Firecracker
"$STATE_DIR/bin/firecracker" --api-sock "$SOCK" --id smoke-boot >"$LOG" 2>&1 &
FC_PID=$!
echo "[smoke] firecracker pid=$FC_PID sock=$SOCK"

# Wait for socket
for _ in $(seq 1 40); do
    [ -S "$SOCK" ] && break
    sleep 0.1
done

api() {
    local m="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl --unix-socket "$SOCK" -fsS -X "$m" "http://localhost$path" \
            -H 'Content-Type: application/json' --data "$body"
    else
        curl --unix-socket "$SOCK" -fsS -X "$m" "http://localhost$path"
    fi
}

api PUT /boot-source "$(cat <<EOF
{"kernel_image_path": "$STATE_DIR/kernel/vmlinux",
 "boot_args": "console=ttyS0 reboot=k panic=1 pci=off ip=${GUEST_IP}::${HOST_IP}:255.255.255.0::eth0:off root=/dev/vda rw init=/lib/systemd/systemd"}
EOF
)"
api PUT /drives/rootfs "$(cat <<EOF
{"drive_id": "rootfs", "path_on_host": "$STATE_DIR/base-rootfs.ext4",
 "is_root_device": true, "is_read_only": false}
EOF
)"
api PUT /network-interfaces/eth0 "$(cat <<EOF
{"iface_id": "eth0", "guest_mac": "02:fc:00:00:00:fa",
 "host_dev_name": "$TAP"}
EOF
)"
api PUT /machine-config '{"vcpu_count": 2, "mem_size_mib": 2048, "smt": false}'
api PUT /actions '{"action_type": "InstanceStart"}'

# Poll the agent for liveness
echo "[smoke] waiting for agent at http://${GUEST_IP}:8080/health"
ok=0
for i in $(seq 1 120); do
    if curl -fsS "http://${GUEST_IP}:8080/health" >/dev/null 2>&1; then
        ok=1
        break
    fi
    sleep 1
done

if [ "$ok" = "1" ]; then
    echo "[smoke] OK — agent responded after ${i}s"
    curl -fsS "http://${GUEST_IP}:8080/health" | head -c 200; echo
    echo "[smoke] /stats:"
    curl -fsS "http://${GUEST_IP}:8080/stats" | head -c 400; echo
else
    echo "[smoke] FAIL — agent never responded; firecracker log tail:"
    tail -30 "$LOG"
fi
