#!/usr/bin/env python3
"""
Rewrite ClickBench's partitioned parquet `hits` with Opteryx's own parquet
writer (rugo), at the layout the engine reads fastest. This is the load step of
the opteryx-parquet-rewritten entry; its wall-clock is what `Load time` reports.

Self-contained on purpose: opteryx, rugo and draken all ship in the
`opteryx-core` wheel, so this needs nothing but the benchmark's own install. (The engine repo's
dev/rewrite_parquet_layout.py is dev-only tooling; this is a port of its
per-file mode. Keep them in step.)

One output file per source file, same name. Each file is read whole, written
with rugo.parquet.write_parquet(compression, max_rows_per_row_group,
row_groups_per_block) and the writer's other defaults, and its row count is
checked against the source footer — a mismatch is a hard failure.

RETYPING: the source files carry no logical types — the three time columns are
integer epoch seconds and EventDate is an integer day count. The file is read
through Opteryx (`READ_PARQUET`) with those four columns cast to TIMESTAMP and
DATE (the same retyping the loading entries do in their CREATE TABLE / load);
every other column passes through untouched, in source order. Values are not
changed, only their declared type. Rows are written sorted by the primary key
(most source files are already in that order; a few are two sorted runs, which
the sort merges). Checked after writing: the rows are strictly ascending by the
key and the WatchIDs are the source's — a mismatch is a hard failure.

Usage:  convert.py <src-dir> <dst-dir> <codec> <rows-per-row-group> <row-groups-per-block> [-m GiB]
        codec: zstd|none (what rugo writes)
        -m: memory budget in GiB (default: 70% of MemAvailable, Linux only)

PARALLELISM: processes, not threads (morsel construction holds the GIL), up to
one per core, admitted against a memory budget: a worker holds a whole decoded,
sorted file, so a file is started only when its estimated peak fits in what the
running files leave of the budget. Largest files first; a file whose estimate
exceeds the whole budget runs on its own. One file per process, so a finished
file's memory is returned before the next is admitted.
"""

import multiprocessing
import os
import sys
from concurrent.futures import FIRST_COMPLETED
from concurrent.futures import ProcessPoolExecutor
from concurrent.futures import wait

# Column -> the cast that gives it its logical type.
RETYPE = {
    "EventTime": "TIMESTAMP[s]",
    "ClientEventTime": "TIMESTAMP[s]",
    "LocalEventTime": "TIMESTAMP[s]",
    "EventDate": "DATE",
}

# The benchmark's primary key. Rows are written sorted by it (a clustered
# primary key, which ClickBench allows); the scan does not keep file order.
PRIMARY_KEY = "CounterID, EventDate, UserID, EventTime, WatchID"

# Peak RSS of one worker ~= PEAK_BASE + PEAK_PER_BYTE * source file bytes, fitted
# to two measured 1M-row files (opteryx-core HEAD, 2026-10-13): 112 MB -> 4.7 GB,
# 363 MB (hits_51, the largest) -> 8.3 GB.
PEAK_BASE = 3.1 * 2**30
PEAK_PER_BYTE = 14.3


def rewrite(task):
    src, dst, codec, rows, block = task
    import opteryx
    from draken.morsels.morsel import Morsel
    from rugo.parquet import read_metadata
    from rugo.parquet import write_parquet

    metadata = read_metadata(src)
    expected = metadata.num_rows
    names = [column.name for column in metadata.schema_columns]
    missing = sorted(set(RETYPE) - set(names))
    if missing:
        raise RuntimeError(f"{src}: no column(s) {missing} to retype")
    projection = ", ".join(
        f"{name}::{RETYPE[name]} AS {name}" if name in RETYPE else name for name in names
    )
    morsels = list(
        opteryx.session().execute_to_morsels(
            f"SELECT {projection} FROM READ_PARQUET('{src}') ORDER BY {PRIMARY_KEY}"
        )
    )
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
    key = key_rows(dst)
    if any(key[i] >= key[i + 1] for i in range(len(key) - 1)):
        raise RuntimeError(f"{dst}: rows are not strictly ascending by the primary key")
    if sorted(r[-1] for r in key) != sorted(r[-1] for r in key_rows(src)):
        raise RuntimeError(f"{dst}: WatchIDs differ from {src}")
    return written, len(data)


def key_rows(path):
    from rugo.parquet import read_parquet

    columns = [c.strip() for c in PRIMARY_KEY.split(",")]
    out = []
    with read_parquet(path, columns=columns) as reader:
        for morsel in reader:
            out.extend(zip(*(morsel.column(c.encode()).to_pylist() for c in columns)))
    return out


def memory_budget():
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(int(line.split()[1]) * 1024 * 0.7)
    raise RuntimeError("no MemAvailable in /proc/meminfo; pass -m GiB")


def main():
    argv = sys.argv[1:]
    budget = None
    if "-m" in argv:
        i = argv.index("-m")
        budget = int(float(argv[i + 1]) * 2**30)
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
    if budget is None:
        budget = memory_budget()
    cores = os.cpu_count() or 1
    queue = sorted(
        (
            (PEAK_BASE + PEAK_PER_BYTE * os.path.getsize(os.path.join(src, n)),
             (os.path.join(src, n), os.path.join(dst, n), codec, rows, block))
            for n in names
        ),
        key=lambda job: -job[0],
    )
    results, running, in_use, most = [], {}, 0, 0
    context = multiprocessing.get_context("forkserver")
    with ProcessPoolExecutor(max_workers=cores, mp_context=context, max_tasks_per_child=1) as pool:
        while queue or running:
            # Admit the largest pending file that fits; an empty pool always admits.
            while queue and len(running) < cores:
                fit = next((i for i, (est, _) in enumerate(queue) if in_use + est <= budget), None)
                if fit is None and not running:
                    fit = 0
                if fit is None:
                    break
                est, task = queue.pop(fit)
                running[pool.submit(rewrite, task)] = est
                in_use += est
                most = max(most, len(running))
            done, _ = wait(running, return_when=FIRST_COMPLETED)
            for future in done:
                in_use -= running.pop(future)
                results.append(future.result())
    print(
        f"codec={codec} rows_per_row_group={rows} row_groups_per_block={block} "
        f"budget={budget / 2**30:.1f}GiB cores={cores} most_concurrent={most} "
        f"files={len(results)} rows={sum(r[0] for r in results)} "
        f"bytes={sum(r[1] for r in results)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
