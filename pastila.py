"""Publishing pastes on pastila.nl.

A paste is an insert into pastila's ClickHouse instance; the URL is
https://pastila.nl/?<fingerprint>/<hash> where hash is ClickHouse-flavored
sipHash128 of the stored content and fingerprint groups revisions of similar
texts. Both are reimplementations of the functions in ClickHouse/pastila.

Set DRY_RUN=1 to print what would be posted instead of posting it.
"""

import base64
import gzip
import json
import os
import re
import time
import urllib.request

PASTILA_DB_URL = "https://uzg8q0g12h.eu-central-1.aws.clickhouse.cloud/?user=paste"


def siphash128_hex(data):
    mask = (1 << 64) - 1

    def rotl(x, b):
        return ((x << b) | (x >> (64 - b))) & mask

    v = [0x736F6D6570736575, 0x646F72616E646F6D, 0x6C7967656E657261, 0x7465646279746573]

    def compress():
        v[0] = (v[0] + v[1]) & mask
        v[2] = (v[2] + v[3]) & mask
        v[1] = rotl(v[1], 13)
        v[3] = rotl(v[3], 16)
        v[1] ^= v[0]
        v[3] ^= v[2]
        v[0] = rotl(v[0], 32)
        v[2] = (v[2] + v[1]) & mask
        v[0] = (v[0] + v[3]) & mask
        v[1] = rotl(v[1], 17)
        v[3] = rotl(v[3], 21)
        v[1] ^= v[2]
        v[3] ^= v[0]
        v[2] = rotl(v[2], 32)

    n = len(data)
    offset = 0
    while offset + 8 <= n:
        word = int.from_bytes(data[offset:offset + 8], "little")
        v[3] ^= word
        compress()
        compress()
        v[0] ^= word
        offset += 8
    tail = bytearray(8)
    tail[:n - offset] = data[offset:]
    tail[7] = n & 0xFF
    word = int.from_bytes(tail, "little")
    v[3] ^= word
    compress()
    compress()
    v[0] ^= word
    v[2] ^= 0xFF
    for _ in range(4):
        compress()
    hex32 = format(((v[2] ^ v[3]) << 64) | (v[0] ^ v[1]), "032x")
    return "".join(reversed([hex32[i:i + 2] for i in range(0, 32, 2)]))


def get_fingerprint(text):
    words = re.findall(r"[^\W\d_]{4,100}", text)
    # The fingerprint only groups revisions of a paste for the history view,
    # so unlike the hash it does not have to cover the whole text: cap the
    # work to keep megabyte-sized logs fast.
    triples = [",".join(words[i:i + 3]) for i in range(min(len(words) - 2, 5000))]
    fingerprint = "ffffffff"
    for triple in dict.fromkeys(triples):
        candidate = siphash128_hex(triple.encode())[:8]
        if candidate < fingerprint:
            fingerprint = candidate
    return fingerprint


def post(text, extension="", compress=False, retries=3):
    """Publish an unencrypted paste and return its URL. The extension selects
    how pastila.nl renders it, e.g. ".html"; with compress=True the content
    is stored gzipped (pastila appends ".gz" to the URL and inflates it in
    the browser)."""
    if not text:
        return None
    if compress:
        extension += ".gz"
    if os.environ.get("DRY_RUN"):
        print(f"DRY_RUN: would post {len(text)} bytes to pastila.nl")
        return f"https://pastila.nl/?00000000/dryrun{extension}"
    fingerprint = get_fingerprint(text)
    # Compressed content is binary, so pastila stores it base64-encoded.
    content = (base64.b64encode(gzip.compress(text.encode(), mtime=0)).decode()
               if compress else text)
    content_hash = siphash128_hex(content.encode())
    row = {
        "fingerprint_hex": fingerprint,
        "hash_hex": content_hash,
        "prev_fingerprint_hex": "",
        "prev_hash_hex": "",
        "content": content,
        "is_encrypted": False,
    }
    body = ("INSERT INTO data (fingerprint_hex, hash_hex, prev_fingerprint_hex, "
            "prev_hash_hex, content, is_encrypted) FORMAT JSONEachRow " + json.dumps(row))
    for attempt in range(retries):
        try:
            req = urllib.request.Request(PASTILA_DB_URL, data=body.encode())
            with urllib.request.urlopen(req, timeout=180) as response:
                response.read()
            break
        except Exception:
            if attempt == retries - 1:
                raise
            time.sleep(5)
    return f"https://pastila.nl/?{fingerprint}/{content_hash}{extension}"
