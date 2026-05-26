#!/usr/bin/env python3
"""
Convert hits.parquet to per-column binary files that the BQN query
scripts can read directly via `•FBytes` + `8‿64 •bit._cast`.

Layout written under ./cols/:
  <ColName>.f64   — numeric columns, raw little-endian float64
  <ColName>.str   — concatenated UTF-8 bytes for string columns
  <ColName>.off   — int64 little-endian byte offsets into .str,
                    stored as f64 so BQN's `8‿64 •bit._cast` reads them
                    as plain numbers (count(strings)+1 entries)
"""
import os
import sys

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq

SRC = sys.argv[1] if len(sys.argv) > 1 else "hits.parquet"
DST = sys.argv[2] if len(sys.argv) > 2 else "cols"

os.makedirs(DST, exist_ok=True)

pf = pq.ParquetFile(SRC)
schema = pf.schema_arrow
columns = [schema.field(i).name for i in range(len(schema))]
print(f"columns: {len(columns)}; row groups: {pf.num_row_groups}", flush=True)

STRING_TYPES = (pa.string(), pa.large_string(), pa.binary(), pa.large_binary())

fhs_f64 = {}
fhs_str = {}
fhs_off = {}
str_offsets = {}

for col in columns:
    typ = schema.field(col).type
    if typ in STRING_TYPES or pa.types.is_string(typ) or pa.types.is_binary(typ):
        fhs_str[col] = open(os.path.join(DST, col + ".str"), "wb")
        fhs_off[col] = open(os.path.join(DST, col + ".off"), "wb")
        # First offset is always 0.0 (stored as f64).
        fhs_off[col].write(np.array([0.0], dtype="<f8").tobytes())
        str_offsets[col] = 0
    else:
        fhs_f64[col] = open(os.path.join(DST, col + ".f64"), "wb")

for rg in range(pf.num_row_groups):
    tbl = pf.read_row_group(rg)
    for col in columns:
        arr = tbl.column(col)
        if col in fhs_f64:
            # numpy zero-copy where possible; nulls become 0.0.
            np_arr = arr.to_numpy(zero_copy_only=False).astype("<f8", copy=False)
            fhs_f64[col].write(np_arr.tobytes())
        else:
            # arr is a chunked array of (large_)string. Iterate chunks,
            # build a single concatenated bytes buffer + a vector of
            # absolute byte offsets, write both in one shot per chunk.
            # Cast to a plain (large_)string array so the buffer layout is
            # the well-known 3-buffer form regardless of whether the
            # parquet reader handed us a string, large_string,
            # string_view, dictionary-encoded variant, etc. The cast is
            # zero-copy when the chunk is already in the target layout
            # and copies otherwise.
            base = str_offsets[col]
            arr2 = arr.cast(pa.large_string())
            for chunk in arr2.chunks:
                buf = chunk.buffers()
                raw_offs = np.frombuffer(buf[1], dtype="<i8")
                raw_bytes = buf[2].to_pybytes() if buf[2] is not None else b""
                fhs_str[col].write(raw_bytes)
                # Drop the first offset (running base in this chunk's
                # frame) and shift the rest by the absolute base.
                shifted = (raw_offs[1:].astype("<f8") - raw_offs[0]) + base
                fhs_off[col].write(shifted.tobytes())
                base += len(raw_bytes)
            str_offsets[col] = base
    if rg % 25 == 0 or rg == pf.num_row_groups - 1:
        print(f"  rg {rg} done", flush=True)

for fh in fhs_f64.values():
    fh.close()
for fh in fhs_str.values():
    fh.close()
for fh in fhs_off.values():
    fh.close()

print("prep complete")
