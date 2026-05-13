"""SNI-aware allowlist proxy for sandboxed VMs.

Two listeners:
- HTTPS (default :8443): peeks the TLS ClientHello to read the SNI
  hostname, allowlists it, then bidirectionally splices the raw bytes
  to the real server. No TLS termination, no certificate spoofing —
  end-to-end TLS between VM and S3 is preserved untouched.
- HTTP (default :8080): reads the first request's Host header and
  applies the same allowlist.

Used as a target for iptables REDIRECT rules in net.enable_filtered_internet.
VMs that should only reach s3.amazonaws.com get tcp dpt 443 / 80 from
their TAP REDIRECTed to these ports; the proxy enforces the allowlist
before opening the upstream connection.
"""

from __future__ import annotations

import asyncio
import contextlib
import fnmatch
import logging
import re

log = logging.getLogger("sni_proxy")


# Hostname globs allowed through. Case-insensitive.
DEFAULT_ALLOW: tuple[str, ...] = (
    "s3.amazonaws.com",
    "*.s3.amazonaws.com",
    "s3.*.amazonaws.com",
    "*.s3.*.amazonaws.com",
    # AWS occasionally returns S3 traffic via these "dualstack" names.
    "*.s3-accelerate.amazonaws.com",
    "*.s3-website-*.amazonaws.com",
)


def _allowed(host: str, patterns: tuple[str, ...] | list[str]) -> bool:
    h = host.lower()
    return any(fnmatch.fnmatchcase(h, p.lower()) for p in patterns)


def _parse_sni(data: bytes) -> str | None:
    """Pull SNI hostname out of a TLS ClientHello record (if any).

    Returns None if the bytes aren't a recognizable ClientHello or no
    server_name extension is present.
    """
    # TLS record header: type(1)=0x16, version(2), length(2).
    if len(data) < 5 or data[0] != 0x16:
        return None
    p = 5
    # Handshake header: msg_type(1)=0x01 (ClientHello), length(3).
    if p + 4 > len(data) or data[p] != 0x01:
        return None
    p += 4
    # client_version(2)
    p += 2
    # random(32)
    p += 32
    # session_id
    if p >= len(data):
        return None
    sid_len = data[p]
    p += 1 + sid_len
    # cipher_suites
    if p + 2 > len(data):
        return None
    cs_len = (data[p] << 8) | data[p + 1]
    p += 2 + cs_len
    # compression_methods
    if p >= len(data):
        return None
    cm_len = data[p]
    p += 1 + cm_len
    # extensions
    if p + 2 > len(data):
        return None
    ext_total = (data[p] << 8) | data[p + 1]
    p += 2
    end = min(p + ext_total, len(data))
    while p + 4 <= end:
        ext_type = (data[p] << 8) | data[p + 1]
        ext_len = (data[p + 2] << 8) | data[p + 3]
        p += 4
        if ext_type == 0x00 and p + 2 <= end:
            # server_name list length(2), then list of (type(1),len(2),name).
            sn_list_len = (data[p] << 8) | data[p + 1]
            q = p + 2
            list_end = min(q + sn_list_len, len(data))
            while q + 3 <= list_end:
                name_type = data[q]
                name_len = (data[q + 1] << 8) | data[q + 2]
                q += 3
                if name_type == 0x00 and q + name_len <= list_end:
                    return data[q:q + name_len].decode("ascii", errors="ignore")
                q += name_len
        p += ext_len
    return None


_HOST_HEADER_RE = re.compile(
    rb"\r\nHost:\s*([^\r\n:]+)", re.IGNORECASE,
)


def _parse_http_host(data: bytes) -> str | None:
    m = _HOST_HEADER_RE.search(data)
    if not m:
        return None
    return m.group(1).decode("ascii", errors="ignore").strip()


async def _read_preamble(reader: asyncio.StreamReader,
                          want: int = 4096,
                          timeout: float = 5.0) -> bytes:
    """Read up to `want` bytes of the connection start — enough to
    cover a TLS ClientHello or the start of an HTTP request line +
    headers."""
    buf = bytearray()
    deadline = asyncio.get_event_loop().time() + timeout
    while len(buf) < want:
        remaining = deadline - asyncio.get_event_loop().time()
        if remaining <= 0:
            break
        try:
            chunk = await asyncio.wait_for(
                reader.read(min(4096, want - len(buf))),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            break
        if not chunk:
            break
        buf.extend(chunk)
        # For HTTP we can stop early once we see the end of headers.
        if b"\r\n\r\n" in buf:
            break
    return bytes(buf)


async def _pipe(reader: asyncio.StreamReader,
                  writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(16384)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionResetError, BrokenPipeError, OSError, asyncio.CancelledError):
        pass
    finally:
        with contextlib.suppress(Exception):
            writer.write_eof()
        with contextlib.suppress(Exception):
            writer.close()


async def _handle(reader: asyncio.StreamReader,
                    writer: asyncio.StreamWriter,
                    *, https: bool, allow: tuple[str, ...] | list[str],
                    upstream_port: int) -> None:
    peer = writer.get_extra_info("peername")
    try:
        first = await _read_preamble(reader, want=4096, timeout=5.0)
        host = _parse_sni(first) if https else _parse_http_host(first)
        if not host or not _allowed(host, allow):
            log.info("blocked %s -> %r", peer, host)
            writer.close()
            return
        try:
            upr, upw = await asyncio.wait_for(
                asyncio.open_connection(host, upstream_port),
                timeout=10.0,
            )
        except Exception as e:
            log.warning("upstream %s:%d failed: %r", host, upstream_port, e)
            writer.close()
            return
        log.info("forwarding %s -> %s:%d", peer, host, upstream_port)
        # Replay what we already read.
        upw.write(first)
        with contextlib.suppress(Exception):
            await upw.drain()
        await asyncio.gather(
            _pipe(reader, upw),
            _pipe(upr, writer),
            return_exceptions=True,
        )
    except (asyncio.TimeoutError, OSError):
        with contextlib.suppress(Exception):
            writer.close()


async def start(*, bind_addr: str = "0.0.0.0",
                https_port: int = 8443,
                http_port: int = 8080,
                allow: tuple[str, ...] | list[str] = DEFAULT_ALLOW
                ) -> list[asyncio.AbstractServer]:
    """Start the proxy listeners. Returns the asyncio servers so the
    caller can keep them alive / close them on shutdown."""
    async def https_h(r, w): await _handle(r, w, https=True, allow=allow, upstream_port=443)
    async def http_h(r, w):  await _handle(r, w, https=False, allow=allow, upstream_port=80)
    s_https = await asyncio.start_server(https_h, bind_addr, https_port)
    s_http  = await asyncio.start_server(http_h,  bind_addr, http_port)
    log.info("SNI-filter proxy: https=:%d http=:%d allow=%s",
             https_port, http_port, list(allow))
    return [s_https, s_http]


if __name__ == "__main__":
    # Standalone runner for testing:
    #   python3 -m playground.server.sni_proxy [https_port] [http_port]
    import sys
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    hp = int(sys.argv[1]) if len(sys.argv) > 1 else 8443
    pp = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
    async def main():
        servers = await start(https_port=hp, http_port=pp)
        try:
            await asyncio.gather(*(s.serve_forever() for s in servers))
        finally:
            for s in servers:
                s.close()
    asyncio.run(main())
