#!/usr/bin/env python3
"""
Rewrite ClickBench's partitioned parquet `hits` with Opteryx's own parquet
writer (rugo), at the layout the engine reads fastest. This is the load step of
the opteryx-parquet-rewritten entry; its wall-clock is what `Load time` reports.

Self-contained on purpose: rugo and draken ship inside the `opteryx-core` wheel,
so this needs nothing but the benchmark's own install. (The engine repo's
dev/rewrite_parquet_layout.py is dev-only tooling; this is a port of its
per-file mode. Keep them in step.)

One output file per source file, same name. Each file is read whole, written
with rugo.parquet.write_parquet(compression, max_rows_per_row_group,
row_groups_per_block) and the writer's other defaults, and its row count is
checked against the source footer — a mismatch is a hard failure.

Usage:  convert.py <src-dir> <dst-dir> <codec> <rows-per-row-group> <row-groups-per-block> [-j N]
        codec: zstd|none (what rugo writes)

PARALLELISM: processes, not threads (morsel construction holds the GIL), three
quarters of the cores: a worker holds a whole decoded file.
"""

import os
import sys
from concurrent.futures import ProcessPoolExecutor


def rewrite(task):
    src, dst, codec, rows, block = task
    from draken.morsels.morsel import Morsel
    from rugo.parquet import read_metadata
    from rugo.parquet import read_parquet
    from rugo.parquet import write_parquet

    expected = read_metadata(src).num_rows
    with read_parquet(src) as reader:
        morsels = list(reader)
    morsel = Morsel.combine(morsels) if len(morsels) > 1 else morsels[0]
    data = write_parquet(
        morsel, compression=codec, max_rows_per_row_group=rows, row_groups_per_block=block
    )
    with open(dst + ".tmp", "wb") as f:
        f.write(data)
    os.replace(dst + ".tmp", dst)
    written = read_metadata(dst).num_rows
    if written != expected or morsel.num_rows != expected:
        raise RuntimeError(f"{dst}: wrote {written:,} rows, source holds {expected:,}")
    return written, len(data)


def main():
    argv = sys.argv[1:]
    workers = max(1, (os.cpu_count() or 1) * 3 // 4)
    if "-j" in argv:
        i = argv.index("-j")
        workers = int(argv[i + 1])
        del argv[i : i + 2]
    if len(argv) != 5:
        print(__doc__)
        return 1
    src, dst, codec, rows, block = argv[0], argv[1], argv[2], int(argv[3]), int(argv[4])
    if codec not in ("zstd", "none"):
        print(f"ERROR: rugo writes zstd or none, not {codec!r}")
        return 1
    names = sorted(f for f in os.listdir(src) if f.endswith(".parquet"))
    if not names:
        print(f"ERROR: no parquet files in {src}")
        return 1
    os.makedirs(dst, exist_ok=True)
    if any(f.endswith(".parquet") for f in os.listdir(dst)):
        print(f"ERROR: {dst} already holds parquet files; rm -rf it first")
        return 1
    tasks = [(os.path.join(src, n), os.path.join(dst, n), codec, rows, block) for n in names]
    with ProcessPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(rewrite, tasks))
    print(
        f"codec={codec} rows_per_row_group={rows} row_groups_per_block={block} "
        f"workers={workers} files={len(results)} rows={sum(r[0] for r in results)} "
        f"bytes={sum(r[1] for r in results)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
