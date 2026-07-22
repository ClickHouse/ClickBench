#!/usr/bin/env python3
"""
Convert hits.parquet to per-column raw binary files for GenDB-style
mmap-based query execution.

For each fixed-width column we emit `<gendb_dir>/hits/<col>.bin` containing
the raw little-endian values back-to-back. For each TEXT column we emit two
files: `<col>_off.bin` (uint64 offsets, length = num_rows + 1) and
`<col>_data.bin` (concatenated UTF-8 bytes). This matches the layout the
hand-written per-query C++ binaries expect.

We process columns one at a time (not all at once) so a 100 M-row table fits
even on hosts with ~16 GB RAM. DuckDB does the parquet decode and column
projection; numpy.tofile() does the raw dump.
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

import duckdb
import numpy as np

# Map storage_layout.json "type" -> numpy dtype.
DTYPE_MAP = {
    "int8":  np.int8,
    "int16": np.int16,
    "int32": np.int32,
    "int64": np.int64,
}


def epoch_seconds_to_int32(series):
    """ClickBench's hits.parquet stores EventTime/etc as bigint epoch seconds.
    Yandex's data range fits comfortably in uint32 (2013) but we keep int32
    for safety. Convert directly with numpy."""
    return series.astype(np.int32)


def days_since_epoch(series):
    """EventDate in hits.parquet is a date32 → arrow returns numpy datetime64[D].
    Convert to int32 days-since-1970."""
    if series.dtype == np.int32:
        return series
    # arrow date32 maps to numpy datetime64[D] in some pyarrow versions.
    return series.astype("datetime64[D]").astype(np.int32)


def dump_fixed(con, parquet_path, col_name, dtype_name, out_path):
    """Read one fixed-width column and write its raw bytes to disk."""
    np_dtype = DTYPE_MAP[dtype_name]
    # DuckDB FetchNumpy is the fastest way to get a typed contiguous array.
    result = con.execute(
        f'SELECT "{col_name}" FROM read_parquet(?)', [str(parquet_path)]
    ).fetchnumpy()
    arr = result[col_name]
    if arr.dtype != np_dtype:
        # Date / timestamp columns come back as datetime64 or python objects;
        # coerce to the declared storage dtype.
        if np.issubdtype(arr.dtype, np.datetime64):
            unit = np.datetime_data(arr.dtype)[0]
            if unit == "D":
                arr = arr.astype(np.int64).astype(np_dtype)
            else:
                arr = (arr.astype("datetime64[s]").astype(np.int64)).astype(np_dtype)
        else:
            arr = arr.astype(np_dtype)
    arr.tofile(out_path)
    return arr.nbytes


def dump_string(con, parquet_path, col_name, off_path, data_path):
    """Read one TEXT column and write offsets+data files. We stream by row
    batches because the concatenated data for URL/Referer is multi-GB."""
    rel = con.sql(f'SELECT "{col_name}" FROM read_parquet(\'{parquet_path}\')')
    # PyArrow path: iterate batches, write data and offsets incrementally.
    reader = rel.fetch_arrow_reader(batch_size=1 << 20)

    with open(off_path, "wb") as off_f, open(data_path, "wb") as data_f:
        running_offset = 0
        # Write the leading offset (0) first; we append offsets[i] = end of row i.
        off_f.write(np.uint64(0).tobytes())
        total_rows = 0
        for batch in reader:
            arr = batch.column(0)  # ChunkedArray inside RecordBatch
            # arrow StringArray exposes .buffers(): [validity, offsets, data]
            buffers = arr.buffers()
            offsets_buf = buffers[1]
            data_buf = buffers[2]
            n_rows = len(arr)

            # 32-bit offsets in arrow StringArray.
            offsets = np.frombuffer(offsets_buf, dtype=np.int32, count=n_rows + 1)
            # Slice 0..n+1; last entry is the byte length of this batch's data.
            batch_bytes = int(offsets[-1])

            # Append data bytes.
            if data_buf is not None and batch_bytes > 0:
                # Arrow's data buffer may have allocated more bytes than used;
                # write only the first batch_bytes.
                data_f.write(bytes(data_buf)[:batch_bytes])

            # Append per-row end offsets (skip offsets[0], add running_offset).
            tails = (offsets[1:].astype(np.uint64) + np.uint64(running_offset))
            off_f.write(tails.tobytes())

            running_offset += batch_bytes
            total_rows += n_rows
    return total_rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--parquet", required=True, help="Path to hits.parquet")
    ap.add_argument("--gendb-dir", required=True, help="Output gendb dir")
    ap.add_argument("--layout", required=True, help="storage_layout.json")
    ap.add_argument("--column", default=None,
                    help="Process only this column (for parallel ingestion)")
    args = ap.parse_args()

    layout = json.loads(Path(args.layout).read_text())
    cols = layout["columns"]
    out_dir = Path(args.gendb_dir) / layout["table"]
    out_dir.mkdir(parents=True, exist_ok=True)

    con = duckdb.connect()
    # Bump threads — DuckDB's parquet scan is parallel.
    con.execute("PRAGMA threads=16")
    con.execute("PRAGMA memory_limit='32GB'")

    targets = [c for c in cols if args.column is None or c["name"] == args.column]
    if args.column and not targets:
        print(f"Unknown column: {args.column}", file=sys.stderr)
        sys.exit(1)

    for col in targets:
        name = col["name"]
        if col["type"] == "string":
            off_path = out_dir / f"{name}_off.bin"
            data_path = out_dir / f"{name}_data.bin"
            if off_path.exists() and data_path.exists() and off_path.stat().st_size > 0:
                print(f"skip (exists): {name}")
                continue
            t0 = time.time()
            n = dump_string(con, args.parquet, name, off_path, data_path)
            sz = data_path.stat().st_size
            print(f"{name}: {n} rows, data={sz/1e6:.1f} MB, {time.time()-t0:.1f}s")
        else:
            out_path = out_dir / f"{name}.bin"
            if out_path.exists() and out_path.stat().st_size > 0:
                print(f"skip (exists): {name}")
                continue
            t0 = time.time()
            nb = dump_fixed(con, args.parquet, name, col["type"], out_path)
            print(f"{name}: {nb/1e6:.1f} MB, {time.time()-t0:.1f}s")


if __name__ == "__main__":
    main()
