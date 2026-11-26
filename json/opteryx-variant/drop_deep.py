"""
Copy NDJSON from stdin to stdout, dropping the documents nested deeper than a VARIANT can hold.

    pigz -dc file.json.gz | python drop_deep.py > file.jsonl

rugo's Parquet writer refuses a value nested deeper than 1024 levels (the top-level object is
level 1) and fails the whole file. A few documents of the full dataset (the 1000m size) are
nested deeper than that; they are dropped here, as ../datafusion and ../polars drop them.

A document deeper than the limit has more opening brackets than the limit, so only such lines
are scanned (outside of strings); the rest are copied as they are. Standard library only.
"""

import sys

LIMIT = 1024


def depth(line: bytes) -> int:
    deepest = level = 0
    in_string = escaped = False
    for byte in line:
        if in_string:
            if escaped:
                escaped = False
            elif byte == 0x5C:  # backslash
                escaped = True
            elif byte == 0x22:  # quote
                in_string = False
        elif byte == 0x22:
            in_string = True
        elif byte == 0x7B or byte == 0x5B:  # { [
            level += 1
            deepest = max(deepest, level)
        elif byte == 0x7D or byte == 0x5D:  # } ]
            level -= 1
    return deepest


dropped = 0
out = sys.stdout.buffer
for line in sys.stdin.buffer:
    if line.count(b"{") + line.count(b"[") > LIMIT and depth(line) > LIMIT:
        dropped += 1
        continue
    out.write(line)

if dropped:
    print(f"drop_deep.py: dropped {dropped} documents nested deeper than {LIMIT} levels", file=sys.stderr)
