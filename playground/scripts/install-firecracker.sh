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
# of seconds, and on transparent zstd compression to fit 100 system
# goldens on the host. Btrfs gives us both out of the box. Format the
# playground volume before running install-firecracker.sh:
#
#   sudo mkfs.btrfs -L cbplayground -f /dev/<your-device>
#   echo 'LABEL=cbplayground /opt/clickbench-playground btrfs \
#       defaults,noatime,compress-force=zstd:6,nofail 0 2' | sudo tee -a /etc/fstab
#   sudo mount /opt/clickbench-playground
#
# Notes on the mount options:
#   - compress-force (not compress): the default heuristic samples the
#     first 128 KiB of each file and skips compression if that head
#     looks incompressible. For the ext4 disk images we write, the
#     sparse-metadata head throws off the sampler and ~80 % of the
#     data ends up stored raw. `compress-force` disables the heuristic
#     and gets the whole file compressed.
#   - zstd:6 (not zstd:1): the on-disk savings from 6-vs-1 are modest
#     for the compressible portion (~10 %), but 6's higher ratio adds
#     up over 6+ TiB of goldens. Compression speed drops from ~500
#     MB/s to ~120 MB/s per core — writeback stays disk-bound anyway,
#     and the CPU is otherwise idle during provisioning.
#
# (XFS also works for reflink but doesn't have transparent compression,
# so on XFS the host fills up at ~7 TB once every system is provisioned.)
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

# TLS for the playground API. We use certbot --standalone (binds 80
# briefly for HTTP-01) to acquire / renew a Let's Encrypt cert for
# the public hostname. The unprivileged playground user reads the
# private key via the ssl-cert group; a deploy hook re-applies that
# ownership after every renewal so renewals don't lock us out.
#
# Skipped entirely if PLAYGROUND_TLS_DOMAIN isn't set — operators
# running the playground purely on a private network don't need
# the cert.
if [ -n "${PLAYGROUND_TLS_DOMAIN:-}" ]; then
    sudo apt-get install -y certbot
    getent group ssl-cert >/dev/null || sudo groupadd ssl-cert
    sudo usermod -aG ssl-cert "${SUDO_USER:-ubuntu}"
    if [ ! -d "/etc/letsencrypt/live/${PLAYGROUND_TLS_DOMAIN}" ]; then
        sudo certbot certonly --standalone --non-interactive --agree-tos \
            -m "${PLAYGROUND_TLS_EMAIL:-${SUDO_USER:-ubuntu}@$(hostname -d 2>/dev/null || echo localhost)}" \
            -d "${PLAYGROUND_TLS_DOMAIN}"
    fi
    sudo tee /etc/letsencrypt/renewal-hooks/deploy/clickbench-ssl-cert.sh >/dev/null <<'HOOK'
#!/bin/bash
# Managed by playground/scripts/install-firecracker.sh. After every
# cert renewal, re-apply ssl-cert group ownership so the unprivileged
# playground user can keep reading the new privkey.
set -e
chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive
chmod 750 /etc/letsencrypt/live /etc/letsencrypt/archive
find /etc/letsencrypt/live /etc/letsencrypt/archive -type d -exec chmod 750 {} \;
find /etc/letsencrypt/archive -name "privkey*.pem" -exec chmod 640 {} \;
HOOK
    sudo chmod 755 /etc/letsencrypt/renewal-hooks/deploy/clickbench-ssl-cert.sh
    # Apply once now so the freshly issued cert is readable too.
    sudo bash /etc/letsencrypt/renewal-hooks/deploy/clickbench-ssl-cert.sh
fi

# Local DNS resolver for the VMs. enable_filtered_internet REDIRECTs
# the VM TAP's UDP/53 to the host's port 53. systemd-resolved binds
# only to 127.0.0.53 / .54, so REDIRECT'd traffic (dst=10.200.x.1:53)
# hits a closed port without a real listener. Dnsmasq fills that gap:
# bind every non-loopback address, forward upstream, UDP only from
# the VM side (iptables INPUT drops TCP/53 from VM addresses).
if ! command -v dnsmasq >/dev/null 2>&1; then
    sudo apt-get install -y dnsmasq
fi
sudo tee /etc/dnsmasq.d/playground.conf >/dev/null <<'CONF'
# Managed by playground/scripts/install-firecracker.sh — do not edit.
port=53
bind-interfaces
# systemd-resolved already owns 127.0.0.53/54 on loopback; leave it.
except-interface=lo
no-resolv
server=1.1.1.1
server=8.8.8.8
no-dhcp-interface=
log-queries=no
cache-size=2000
CONF
sudo systemctl enable dnsmasq >/dev/null 2>&1 || true
sudo systemctl restart dnsmasq

echo "[install] done"
"$STATE_DIR/bin/firecracker" --version
