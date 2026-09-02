#!/usr/bin/env python3
"""Feed hits.csv into TDengine as a series of INSERT ... FILE statements.

Usage: load-csv.py <csv> <insert-column-list> <scratch-file>

Two reasons this is not a one-liner in ./load:

Chunking is forced. The taos client materialises an entire INSERT ... FILE
in memory before sending anything, so pointing it at the whole 75 GB
hits.csv fails with "Out of Memory" (0x80000102); it survives ~500 MB per
statement. Chunks are written to one scratch file that is overwritten each
time, so the load needs one chunk of spare disk rather than a second copy
of the dataset.

Chunk boundaries have to respect CSV records, not lines. hits.csv quotes
every string field and a few thousand URL and Referer values contain
literal newlines, so cutting on '\n' would split a row and corrupt it. A
newline ends a record only when an even number of '"' characters precede
it, because a quote inside a quoted field is written doubled and so never
flips the parity. Chunks are byte-exact slices of the input -- nothing is
re-encoded, so every value reaches the server with its original bytes,
including the non-UTF-8 ones hits contains.
"""
import os
import subprocess
import sys

READ_SIZE = 1 << 22
DB = os.environ.get("TDENGINE_DB", "clickbench")
# 128 MB: comfortably under the size at which the client runs out of memory,
# and small enough that its peak RSS (~3.5x the chunk) still fits on the
# 2 GB t3a.small.
CHUNK = int(os.environ.get("TDENGINE_CHUNK_BYTES", 1 << 27))


def chunks(fh, target):
    """Yield byte-exact slices of fh, each >= target bytes, cut at a record end."""
    out = bytearray()
    parity = 0
    tail = b""
    while True:
        block = tail or fh.read(READ_SIZE)
        tail = b""
        if not block:
            break
        if len(out) < target:
            out += block
            parity ^= block.count(b'"') & 1
            continue
        cut = -1
        pos = 0
        while True:
            nl = block.find(b"\n", pos)
            if nl < 0:
                out += block[pos:]
                parity ^= block[pos:].count(b'"') & 1
                break
            parity ^= block[pos:nl + 1].count(b'"') & 1
            if parity == 0:
                out += block[pos:nl + 1]
                cut = nl + 1
                break
            pos = nl + 1
        if cut >= 0:
            tail = block[cut:]
            yield bytes(out)
            out = bytearray()
            parity = 0
    if out:
        yield bytes(out)


def main():
    csv_path, columns, scratch = sys.argv[1], sys.argv[2], sys.argv[3]
    sql = "INSERT INTO hits (%s) FILE '%s'" % (columns, os.path.abspath(scratch))
    done = 0
    total = os.path.getsize(csv_path)
    with open(csv_path, "rb") as fh:
        for n, chunk in enumerate(chunks(fh, CHUNK)):
            with open(scratch, "wb") as tmp:
                tmp.write(chunk)
            res = subprocess.run(["taos", "-d", DB, "-s", sql],
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
            out = res.stdout or ""
            if res.returncode != 0 or "Insert OK" not in out:
                sys.stderr.write("load: chunk %d failed:\n%s\n" % (n, out[-2000:]))
                return 1
            done += len(chunk)
            sys.stderr.write("load: chunk %d, %d/%d bytes\n" % (n, done, total))
    if os.path.exists(scratch):
        os.unlink(scratch)
    return 0


if __name__ == "__main__":
    sys.exit(main())
