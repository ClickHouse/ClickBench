#!/usr/bin/env python3

"""
Usage: load.py <data_dir> <num_files>

Loads the first <num_files> file_*.json.gz NDJSON files from <data_dir> into
Zstd-compressed Parquet shards under bluesky/, storing each raw JSON document
in a single String column `j` (retaining the original JSON structure without
flattening at insertion time).

A few lines in the dataset are invalid JSON or invalid UTF-8 (documents >64 KiB
split across two lines, sometimes mid-UTF-8 character, or nested >2000 levels
deep): utf8-lossy + JSON-object validation filters them out.
"""

import glob
import os
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor

os.environ.setdefault("POLARS_MAX_THREADS", "2")

import polars as pl

TABLE_DIR = "bluesky"


def convert_one(args: tuple[int, str]) -> int:
    idx, path = args
    df = pl.read_csv(
        path,
        has_header=False,
        new_columns=["j"],
        separator="\x1f",
        quote_char=None,
        encoding="utf8-lossy",
        ignore_errors=True,
        truncate_ragged_lines=True,
    )
    raw_rows = df.height
    df = df.filter(
        pl.col("j").str.strip_chars().str.starts_with("{")
        & pl.col("j").str.json_path_match("$").is_not_null()
    )
    out_path = os.path.join(TABLE_DIR, f"part_{idx:04d}.parquet")
    df.write_parquet(out_path, compression="zstd")
    return raw_rows - df.height


def main() -> None:
    data_dir = sys.argv[1]
    num_files = int(sys.argv[2])
    files = sorted(glob.glob(os.path.join(data_dir, "file_*.json.gz")))[:num_files]
    if not files:
        print(f"load: no file_*.json.gz found in {data_dir}", file=sys.stderr)
        sys.exit(1)

    shutil.rmtree(TABLE_DIR, ignore_errors=True)
    os.makedirs(TABLE_DIR)

    workers = min(len(files), max(1, (os.cpu_count() or 4) // 2), 16)
    with ProcessPoolExecutor(max_workers=workers) as pool:
        skipped = sum(pool.map(convert_one, enumerate(files, start=1)))

    if skipped:
        print(f"load: skipped {skipped} invalid lines", file=sys.stderr)


if __name__ == "__main__":
    main()
