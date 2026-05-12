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


async def enable_internet(slot: int) -> None:
    """Allow the VM to reach the outside world via MASQUERADE + FORWARD."""
    iface = await _host_default_iface()
    _, _, cidr = addr_for(slot)
    # MASQUERADE rule: add only if not already present.
    rc, out, _ = await _run("sudo", "iptables", "-t", "nat", "-S", "POSTROUTING")
    if f"-s {cidr}" not in out.decode(errors="replace"):
        await _run("sudo", "iptables", "-t", "nat", "-A", "POSTROUTING",
                   "-s", cidr, "-o", iface, "-j", "MASQUERADE")
    # FORWARD rules
    for rule in (
        ("-i", tap_name(slot), "-o", iface, "-j", "ACCEPT"),
        ("-i", iface, "-o", tap_name(slot), "-m", "state", "--state",
         "RELATED,ESTABLISHED", "-j", "ACCEPT"),
    ):
        rc, out, _ = await _run("sudo", "iptables", "-C", "FORWARD", *rule, check=False)
        if rc != 0:
            await _run("sudo", "iptables", "-A", "FORWARD", *rule)


async def disable_internet(slot: int) -> None:
    """Drop the masquerade + forward rules added by enable_internet."""
    iface = await _host_default_iface()
    _, _, cidr = addr_for(slot)
    # Best-effort removal — repeat until iptables reports the rule isn't there.
    while True:
        rc, _, _ = await _run("sudo", "iptables", "-t", "nat", "-D", "POSTROUTING",
                              "-s", cidr, "-o", iface, "-j", "MASQUERADE", check=False)
        if rc != 0:
            break
    for rule in (
        ("-i", tap_name(slot), "-o", iface, "-j", "ACCEPT"),
        ("-i", iface, "-o", tap_name(slot), "-m", "state", "--state",
         "RELATED,ESTABLISHED", "-j", "ACCEPT"),
    ):
        while True:
            rc, _, _ = await _run("sudo", "iptables", "-D", "FORWARD", *rule, check=False)
            if rc != 0:
                break
