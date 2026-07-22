"""Per-VM TAP networking setup for Firecracker.

Each VM gets its own /24 subnet on a dedicated TAP device:

    fc-tap-<id>    host: 10.200.<id>.1/24    vm: 10.200.<id>.2

Where <id> is a small integer derived from the system slot (1..N). The /24 has
plenty of headroom but only two addresses are used — one /24 per VM keeps the
host's routing trivial: no shared bridge, no ARP nonsense, no collisions.

During the *provision* phase we masquerade outbound traffic from the VM so it
can apt-get / curl. After the snapshot we drop the FORWARD rules; the VM can
still talk to the host (and therefore the agent endpoint) but cannot reach the
internet.
"""
from __future__ import annotations

import asyncio
import contextlib
import re

# The /16 we hand out from. 10.200.0.0/16 -> 256 /24 subnets, plenty for our use.
_BASE = "10.200"


def addr_for(slot: int) -> tuple[str, str, str]:
    """Return (host_ip, vm_ip, cidr) for the given slot id."""
    if not 1 <= slot <= 250:
        raise ValueError(f"slot out of range: {slot}")
    return f"{_BASE}.{slot}.1", f"{_BASE}.{slot}.2", f"{_BASE}.{slot}.0/24"


def tap_name(slot: int) -> str:
    return f"fc-tap-{slot}"


def mac_for(slot: int) -> str:
    # Locally administered, unicast, deterministic by slot.
    return f"02:fc:00:00:{slot // 256:02x}:{slot % 256:02x}"


async def _run(*args: str, check: bool = True) -> tuple[int, bytes, bytes]:
    p = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    o, e = await p.communicate()
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(args)}: {e.decode(errors='replace')}")
    return p.returncode or 0, o, e


async def ensure_tap(slot: int) -> None:
    """Create the TAP device and assign the host-side address. Idempotent."""
    tap = tap_name(slot)
    host_ip, _, _ = addr_for(slot)
    # Does the device already exist?
    rc, out, _ = await _run("ip", "-br", "link", "show", "dev", tap, check=False)
    if rc != 0:
        await _run("sudo", "ip", "tuntap", "add", "dev", tap, "mode", "tap")
    # Make sure the IP is there
    rc, addrs, _ = await _run("ip", "-br", "addr", "show", "dev", tap, check=False)
    if rc != 0 or host_ip not in addrs.decode(errors="replace"):
        # Strip any old IPs then add the canonical one.
        await _run("sudo", "ip", "addr", "flush", "dev", tap, check=False)
        await _run("sudo", "ip", "addr", "add", f"{host_ip}/24", "dev", tap)
    await _run("sudo", "ip", "link", "set", tap, "up")


async def teardown_tap(slot: int) -> None:
    tap = tap_name(slot)
    with contextlib.suppress(Exception):
        await _run("sudo", "ip", "link", "set", tap, "down", check=False)
    with contextlib.suppress(Exception):
        await _run("sudo", "ip", "tuntap", "del", "dev", tap, "mode", "tap", check=False)


_NAT_RULE_PAT = re.compile(r"^-A POSTROUTING.*-o\s+(\S+).*-j\s+MASQUERADE", re.MULTILINE)


async def _host_default_iface() -> str:
    """Return the host's default outbound interface (e.g. eth0)."""
    rc, out, _ = await _run("ip", "-o", "-4", "route", "show", "default")
    text = out.decode(errors="replace")
    # "default via 1.2.3.4 dev eth0 ..."
    parts = text.split()
    for i, p in enumerate(parts):
        if p == "dev" and i + 1 < len(parts):
            return parts[i + 1]
    raise RuntimeError(f"could not find default route: {text!r}")


async def _strip_slot(slot: int) -> None:
    """Remove every iptables rule that mentions this slot's TAP or CIDR.

    Each enable/disable function calls this before installing its own
    rules. That removes the previous mode's rules cleanly and avoids
    the rule-order trap where, e.g., a 'disable_internet' catch-all
    DROP added earlier sits ABOVE the RELATED-ESTABLISHED ACCEPT a
    later 'enable_filtered_internet' wants to add — which would
    silently block all reply traffic to the VM.
    """
    tap = tap_name(slot)
    _, _, cidr = addr_for(slot)
    needle_tap = f" {tap} "  # match -i/-o flags' value with surrounding spaces
    needle_cidr = f" {cidr} "

    for table, chain in (("filter", "FORWARD"),
                         ("nat", "POSTROUTING"),
                         ("nat", "PREROUTING")):
        rc, out, _ = await _run("sudo", "iptables", "-t", table, "-S", chain,
                                check=False)
        if rc != 0:
            continue
        for line in out.decode(errors="replace").splitlines():
            if not line.startswith("-A "):
                continue
            padded = " " + line + " "
            if needle_tap not in padded and needle_cidr not in padded:
                continue
            # Convert "-A CHAIN ..." into "-D CHAIN ..." for deletion.
            args = line.split()
            args[0] = "-D"
            await _run("sudo", "iptables", "-t", table, *args, check=False)


async def enable_internet(slot: int) -> None:
    """Allow the VM to reach the outside world via MASQUERADE + FORWARD."""
    await _strip_slot(slot)
    iface = await _host_default_iface()
    tap = tap_name(slot)
    _, _, cidr = addr_for(slot)
    await _run("sudo", "iptables", "-t", "nat", "-A", "POSTROUTING",
               "-s", cidr, "-o", iface, "-j", "MASQUERADE")
    for rule in (
        ("-i", tap, "-o", iface, "-j", "ACCEPT"),
        ("-i", iface, "-o", tap, "-m", "state", "--state",
         "RELATED,ESTABLISHED", "-j", "ACCEPT"),
    ):
        await _run("sudo", "iptables", "-A", "FORWARD", *rule)


# Ports the SNI-filtering proxy listens on (see sni_proxy.py). Kept in
# sync with the values in main.py.
PROXY_HTTPS_PORT = 8443
PROXY_HTTP_PORT = 8080

# /16 we hand TAP addresses out of — used to scope INPUT firewall rules.
_INTERNAL_CIDR = f"{_BASE}.0.0/16"


async def setup_host_firewall() -> None:
    """Install INPUT rules so the SNI proxy + local DNS resolver are
    only reachable from the per-VM TAPs (10.200.0.0/16) and loopback.
    Run once at server startup.

    Why this matters: sni_proxy.py binds 0.0.0.0:{8443,8080} so the
    iptables PREROUTING REDIRECT from the VM's TAP can find it
    regardless of which TAP IP the kernel routes the redirected
    packet to. Without these INPUT rules the proxy would be an
    open, unauthenticated S3 allowlist relay reachable from the
    public internet. Same logic for the host's UDP/53 resolver.

    Per-protocol source allowlists:
      TCP 8080 / 8443 (SNI proxy): internal CIDR + loopback.
      UDP 53 (DNS):                internal CIDR + loopback.
      TCP 53 (DNS):                loopback only — VMs must use UDP.
                                   Big-payload DNS-over-TCP is a
                                   classic exfiltration channel.
    """
    # (proto, dport, allowed_sources)
    ports = (
        ("tcp", str(PROXY_HTTPS_PORT), (_INTERNAL_CIDR, "127.0.0.0/8")),
        ("tcp", str(PROXY_HTTP_PORT),  (_INTERNAL_CIDR, "127.0.0.0/8")),
        ("udp", "53",                  (_INTERNAL_CIDR, "127.0.0.0/8")),
        # TCP/53 explicitly loopback-only: VMs are not allowed to use
        # DNS-over-TCP. enable_filtered_internet's FORWARD DROP already
        # covers the routed path; this closes the alternate path where
        # a VM addresses the host's TAP IP directly.
        ("tcp", "53",                  ("127.0.0.0/8",)),
    )
    for proto, dport, sources in ports:
        for src in sources:
            allow = ("-p", proto, "--dport", dport, "-s", src, "-j", "ACCEPT")
            rc, _, _ = await _run("sudo", "iptables", "-C", "INPUT",
                                  *allow, check=False)
            if rc != 0:
                # Insert at the top so we override any permissive default.
                await _run("sudo", "iptables", "-I", "INPUT", "1", *allow)
        drop = ("-p", proto, "--dport", dport, "-j", "DROP")
        rc, _, _ = await _run("sudo", "iptables", "-C", "INPUT",
                              *drop, check=False)
        if rc != 0:
            await _run("sudo", "iptables", "-A", "INPUT", *drop)


async def enable_filtered_internet(slot: int) -> None:
    """Allow the VM to reach the *allowlisted* outside world only.

    PREROUTING REDIRECTs:
      - TCP 443/80 → the host's SNI-filtering proxy.
      - UDP 53    → the host's local DNS resolver (operator must run
                    a UDP-only resolver on the host — see
                    playground/scripts/install-firecracker.sh).
    TCP 53 is dropped entirely (no big-payload DNS, the classic
    exfiltration channel — see GHSA / RFC1918 advisories cited in
    the security review). Every other outbound port from the VM is
    DROPped at FORWARD.

    No POSTROUTING MASQUERADE here: the SNI proxy on the host opens
    its OWN outbound socket to the allowlisted upstream, so the
    host's normal egress path handles the source rewrite. The VM's
    only legitimate outbound traffic now goes via REDIRECT to a
    local listener; nothing on the VM's CIDR ever reaches the
    outside interface directly.
    """
    await _strip_slot(slot)
    tap = tap_name(slot)
    iface = await _host_default_iface()

    # NAT redirects: TCP 443/80 → SNI proxy, UDP 53 → host DNS resolver.
    for match in (
        ("-i", tap, "-p", "tcp", "--dport", "443",
         "-j", "REDIRECT", "--to-ports", str(PROXY_HTTPS_PORT)),
        ("-i", tap, "-p", "tcp", "--dport", "80",
         "-j", "REDIRECT", "--to-ports", str(PROXY_HTTP_PORT)),
        ("-i", tap, "-p", "udp", "--dport", "53",
         "-j", "REDIRECT", "--to-ports", "53"),
    ):
        await _run("sudo", "iptables", "-t", "nat", "-A", "PREROUTING", *match)

    # FORWARD: drop TCP/53 + UDP/53 (DNS-over-TCP is a classic exfil
    # channel; UDP/53 is REDIRECTed above, this is a belt-and-braces
    # for a downed resolver). Allow established replies for the SNI
    # proxy's outbound to upstream. Catch-all DROP at the end.
    for rule in (
        ("-i", tap, "-p", "udp", "--dport", "53", "-j", "DROP"),
        ("-i", tap, "-p", "tcp", "--dport", "53", "-j", "DROP"),
        ("-i", iface, "-o", tap, "-m", "state", "--state",
         "RELATED,ESTABLISHED", "-j", "ACCEPT"),
        ("-i", tap, "-j", "DROP"),
    ):
        await _run("sudo", "iptables", "-A", "FORWARD", *rule)


async def disable_internet(slot: int) -> None:
    """Isolate the VM: remove every per-slot rule and install per-slot
    catch-all DROPs (both directions) so the VM cannot reach the
    outside world via FORWARD's default policy.

    Why the explicit DROPs are necessary: the host's FORWARD policy
    is ACCEPT (Docker would flip it but we disable Docker's iptables
    management, and we don't want to flip the global policy ourselves
    — it would break unrelated forwarding on the host). With just the
    per-slot ACCEPTs removed, a 'disabled' VM still has clear egress
    because every FORWARD packet falls through to the default ACCEPT.
    Notably this lets a VM reach 169.254.169.254 (EC2 IMDS) — even
    without our MASQUERADE rule the AWS hypervisor responds to the
    VM's RFC1918 source, and the reply gets forwarded back the same
    way. Any system exposing arbitrary code execution to the
    benchmark consumer (pandas, polars, dataframe variants) could
    then pivot to the host's IAM role.
    """
    await _strip_slot(slot)
    tap = tap_name(slot)
    for rule in (
        ("-i", tap, "-j", "DROP"),
        ("-o", tap, "-j", "DROP"),
    ):
        await _run("sudo", "iptables", "-A", "FORWARD", *rule)
