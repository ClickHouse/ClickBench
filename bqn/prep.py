#!/usr/bin/env python3
"""
Convert hits.parquet to per-column binary files that the BQN query
scripts can read directly via `•FBytes` + `8‿64 •bit._cast`.

Layout written under ./cols/:
  <ColName>.f64           — numeric columns, raw little-endian float64
  <ColName>.str           — concatenated UTF-8 bytes for string columns
  <ColName>.off           — int64 little-endian offsets into .str
                            (count(strings)+1 entries, stored as f64 so
                            BQN's `8‿64 •bit._cast` reads them directly)

The BQN read helper in ./load.bqn understands this layout.
"""
import os
import struct
import sys

import pyarrow.parquet as pq

SRC = sys.argv[1] if len(sys.argv) > 1 else "hits.parquet"
DST = sys.argv[2] if len(sys.argv) > 2 else "cols"

EPOCH_DAY = 719162  # days from 0001-01-01 to 1970-01-01; not used, see below.

os.makedirs(DST, exist_ok=True)

pf = pq.ParquetFile(SRC)
schema = pf.schema_arrow
columns = [schema.field(i).name for i in range(len(schema))]
print(f"columns: {len(columns)}; row groups: {pf.num_row_groups}", flush=True)

# Open one file handle per column (binary append).
fhs_f64 = {}
fhs_str = {}
fhs_off = {}
str_offsets = {}  # current byte offset per string column

for col in columns:
    typ = schema.field(col).type
    if str(typ) in ("string", "large_string", "binary", "large_binary"):
        fhs_str[col] = open(os.path.join(DST, col + ".str"), "wb")
        fhs_off[col] = open(os.path.join(DST, col + ".off"), "wb")
        # First offset is always 0.
        fhs_off[col].write(struct.pack("<d", 0.0))
        str_offsets[col] = 0
    else:
        fhs_f64[col] = open(os.path.join(DST, col + ".f64"), "wb")

for rg in range(pf.num_row_groups):
    tbl = pf.read_row_group(rg)
    for col in columns:
        arr = tbl.column(col)
        if col in fhs_f64:
            # Convert to Python list of floats; numeric arrays from
            # pyarrow expose .to_pylist() which yields ints/floats.
            vals = arr.to_pylist()
            buf = struct.pack(f"<{len(vals)}d", *[float(v) if v is not None else 0.0 for v in vals])
            fhs_f64[col].write(buf)
        else:
            for s in arr.to_pylist():
                if s is None:
                    s = ""
                b = s.encode("utf-8") if isinstance(s, str) else bytes(s)
                fhs_str[col].write(b)
                str_offsets[col] += len(b)
                fhs_off[col].write(struct.pack("<d", float(str_offsets[col])))
    if rg % 25 == 0:
        print(f"  rg {rg} done", flush=True)

for fh in fhs_f64.values():
    fh.close()
for fh in fhs_str.values():
    fh.close()
for fh in fhs_off.values():
    fh.close()

print("prep complete")
