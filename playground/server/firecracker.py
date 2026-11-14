"""Thin async wrapper around Firecracker's REST API (Unix socket).

We talk to the Firecracker process through its API socket, not the JSON config
file, because that's the only way to drive snapshot create/load and to mutate
runtime state.

The HTTP layer is hand-rolled (single-shot HTTP/1.1 over Unix socket) so we
don't pull in extra deps just to send a few PUTs. Each call opens a new
connection — Firecracker's API socket is single-threaded and that's fine.
"""
from __future__ import annotations

import asyncio
import json
from typing import Any


class FirecrackerError(RuntimeError):
    pass


async def _request(socket_path: str, method: str, path: str, body: Any = None,
                   timeout: float = 30.0) -> tuple[int, bytes]:
    payload = b""
    if body is not None:
        payload = json.dumps(body).encode()
    req_lines = [
        f"{method} {path} HTTP/1.1",
        "Host: localhost",
        "Accept: application/json",
        "Connection: close",
    ]
    if payload:
        req_lines.append("Content-Type: application/json")
        req_lines.append(f"Content-Length: {len(payload)}")
    req_lines.append("")
    req_lines.append("")
    head = "\r\n".join(req_lines).encode()

    reader, writer = await asyncio.wait_for(
        asyncio.open_unix_connection(socket_path), timeout=timeout
    )
    try:
        writer.write(head + payload)
        await writer.drain()
        # Read response head line-by-line until the blank line that ends the
        # header block. Don't `read(-1)` — Firecracker keeps the connection
        # open after small responses (204s in particular), so EOF-based reads
        # block until our timeout despite the response being fully on the
        # wire. Once we have headers we know the Content-Length and can read
        # exactly that many body bytes.
        head_lines: list[bytes] = []
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=timeout)
            if not line:
                # Server closed the connection mid-headers.
                break
            head_lines.append(line)
            if line == b"\r\n" or line == b"\n":
                break

        if not head_lines:
            raise FirecrackerError(f"no response from firecracker for {method} {path}")
        status_line = head_lines[0].rstrip(b"\r\n").decode("ascii", errors="replace")
        parts = status_line.split(" ", 2)
        if len(parts) < 2:
            raise FirecrackerError(f"bad status line: {status_line!r}")
        code = int(parts[1])

        content_length = 0
        for raw_h in head_lines[1:]:
            h = raw_h.rstrip(b"\r\n")
            if not h:
                continue
            name, _, value = h.partition(b":")
            if name.strip().lower() == b"content-length":
                try:
                    content_length = int(value.strip())
                except ValueError:
                    content_length = 0

        body_b = b""
        if content_length > 0:
            body_b = await asyncio.wait_for(
                reader.readexactly(content_length), timeout=timeout
            )
    finally:
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass
    return code, body_b


async def put(socket_path: str, path: str, body: Any = None, timeout: float = 30.0) -> None:
    code, b = await _request(socket_path, "PUT", path, body, timeout)
    if code >= 300:
        raise FirecrackerError(f"PUT {path} -> {code}: {b!r}")


async def patch(socket_path: str, path: str, body: Any = None, timeout: float = 30.0) -> None:
    code, b = await _request(socket_path, "PATCH", path, body, timeout)
    if code >= 300:
        raise FirecrackerError(f"PATCH {path} -> {code}: {b!r}")


async def get(socket_path: str, path: str, timeout: float = 30.0) -> dict:
    code, b = await _request(socket_path, "GET", path, timeout=timeout)
    if code >= 300:
        raise FirecrackerError(f"GET {path} -> {code}: {b!r}")
    if not b:
        return {}
    try:
        return json.loads(b)
    except Exception as e:
        raise FirecrackerError(f"GET {path} -> non-JSON body: {b!r}") from e
