#!/usr/bin/env python3
"""
Convert ClickBench's partitioned parquet `hits` into its skene mirror.

Self-contained on purpose: skene, draken and rugo all ship inside the
`opteryx-core` wheel, so this needs nothing but the benchmark's own install.
(The engine repo's dev/parquet_to_skene.py is dev-only tooling and is not
available to a ClickBench run. This file is a port of it; keep them in step.)

Packing: 16 row groups per file at 262144 rows per row group, matching the
engine's own mirrors. Packing is per DIRECTORY, not per file — a row group can
span two source files, so output files do not correspond to input files.

PARALLELISM: conversion runs across PROCESSES, not threads. Both hot phases
release the GIL (rugo's decode, skene's add_row_group/write_to), but the morsel
construction between them does not, which caps a thread pool at ~2.5x against
~5x for processes. Morsels hold raw pointers and cannot cross a process
boundary, so a worker owns a CONTIGUOUS RANGE OF INPUT FILES end to end and
writes its own output files; only counts come back.

CONSEQUENCE — the output is NOT byte-identical to a serial build. Row groups do
not span chunk boundaries, so each worker's last row group is short, where
serially only the very last one was. On this dataset that is ~16 short row
groups of ~397 rather than 1. The layout is a function of the worker count;
`-j 1` reproduces the serial layout exactly. ROW COUNT is invariant, is checked
per chunk against the source footers, and a mismatch is a hard failure.

Usage:  convert.py <src-dir> <dst-dir> [codec] [-j N]   codec: none|lz4|zstd
"""

import os
import sys
from concurrent.futures import ProcessPoolExecutor

import skene
from draken.morsels.morsel import Morsel
from rugo.parquet import read_metadata
from rugo.parquet import read_parquet

ROWS_PER_ROW_GROUP = 262144
ROW_GROUPS_PER_FILE = 16


class Packer:
    def __init__(self, out_dir, stem, codec, zstd_level, first_index=0):
        self.out_dir = out_dir
        self.stem = stem
        self.codec = codec
        self.zstd_level = zstd_level
        self._writer = None
        self._pending = []
        self._pending_rows = 0
        self._row_groups_in_file = 0
        self.files = 0
        self.rows = 0
        self.nbytes = 0
        # Each worker reserves a disjoint output index range, so two workers
        # can never write the same filename.
        self._first_index = first_index
        os.makedirs(out_dir, exist_ok=True)

    def add(self, morsel):
        if morsel.num_rows == 0:
            return
        self._pending.append(morsel)
        self._pending_rows += morsel.num_rows
        while self._pending_rows >= ROWS_PER_ROW_GROUP:
            merged = self._merge()
            self._emit(merged.slice(0, ROWS_PER_ROW_GROUP))
            remainder = merged.num_rows - ROWS_PER_ROW_GROUP
            if remainder > 0:
                self._pending = [merged.slice(ROWS_PER_ROW_GROUP, remainder)]
            else:
                self._pending = []
            self._pending_rows = remainder

    def _merge(self):
        # Morsel has no `concat`; `combine` is the n-way merge. Getting this
        # wrong loses rows silently, which a benchmark cannot survive.
        return self._pending[0] if len(self._pending) == 1 else Morsel.combine(self._pending)

    def close(self):
        # The final row group is SHORT, and so is the final file - a dataset
        # does not divide evenly and padding or dropping the tail are both wrong.
        if self._pending_rows > 0:
            self._emit(self._merge())
            self._pending = []
            self._pending_rows = 0
        self._close_file()

    def _emit(self, row_group):
        if self._writer is None:
            self._writer = skene.SkeneWriter(
                read_acceleration=True, codec=self.codec, zstd_level=self.zstd_level
            )
            self._row_groups_in_file = 0
        self._writer.add_row_group(row_group)
        self._row_groups_in_file += 1
        self.rows += row_group.num_rows
        if self._row_groups_in_file >= ROW_GROUPS_PER_FILE:
            self._close_file()

    def _close_file(self):
        if self._writer is None:
            return
        index = self._first_index + self.files
        path = os.path.join(self.out_dir, f"{self.stem}-{index:04d}.skene")
        # write_to() completes the file in place; finish() would double peak RSS
        # on a wide schema for bytes nobody keeps.
        self.nbytes += self._writer.write_to(path)
        self.files += 1
        self._writer = None
        self._row_groups_in_file = 0


def convert_dir(paths, out_dir, stem, codec, zstd_level, first_index=0):
    packer = Packer(out_dir, stem, codec, zstd_level, first_index)
    for p in paths:
        with read_parquet(p) as reader:
            for morsel in reader:
                packer.add(morsel)
    packer.close()
    return packer.files, packer.rows, packer.nbytes


def _default_workers():
    """Three quarters of the cores, never all of them.

    Saturating the cores measured ~50% SLOWER than the plateau: a worker holds
    a whole decoded file plus up to ROW_GROUPS_PER_FILE row groups buffered in
    its writer, so the run goes memory- and scheduler-bound.
    """
    return max(1, (os.cpu_count() or 1) * 3 // 4)


def _output_files_for(rows):
    """Exactly how many .skene files a chunk of `rows` rows produces — this is
    what reserves each worker's output index range, so it must be exact."""
    if rows == 0:
        return 0
    row_groups = -(-rows // ROWS_PER_ROW_GROUP)
    return -(-row_groups // ROW_GROUPS_PER_FILE)


def _plan_chunks(paths, row_counts, workers):
    """Split into <= `workers` CONTIGUOUS chunks of whole files, balanced by ROW
    COUNT rather than file count. Returns [(paths, rows)] in input order so
    output names stay sequential."""
    total = sum(row_counts)
    # Never split into more chunks than there are full output files of rows:
    # each chunk starts a new output file, so over-splitting a small table
    # shatters it into undersized files with undersized row groups — precisely
    # what packing 16 row groups per file exists to avoid.
    rows_per_file = ROWS_PER_ROW_GROUP * ROW_GROUPS_PER_FILE
    n = min(workers, len(paths), max(1, total // rows_per_file))
    if n <= 1 or total == 0:
        return [(list(paths), total)]

    chunks = []
    start = 0
    assigned = 0
    for _ in range(n - 1):
        remaining_chunks = n - len(chunks) - 1
        target = (total - assigned) / (remaining_chunks + 1)
        rows = 0
        end = start
        while end < len(paths):
            if len(paths) - (end + 1) < remaining_chunks:
                break
            rows += row_counts[end]
            end += 1
            if rows >= target:
                break
        if end == start:
            break
        chunks.append((paths[start:end], rows))
        assigned += rows
        start = end
    if start < len(paths):
        chunks.append((paths[start:], sum(row_counts[start:])))
    return chunks


def _convert_chunk(task):
    """Process-pool entry point. Top-level and picklable-only arguments because
    spawn-start platforms re-import this module in the child."""
    paths, out_dir, stem, codec, zstd_level, first_index, expected_rows = task
    files, rows, nbytes = convert_dir(paths, out_dir, stem, codec, zstd_level, first_index)
    if rows != expected_rows:
        # Catches the failure that destroyed an earlier converter quietly: a bad
        # morsel merge dropped 76% of the rows and still produced a plausible,
        # fast, completely wrong dataset.
        raise RuntimeError(
            f"{out_dir}: chunk at index {first_index} wrote {rows:,} rows "
            f"but its sources hold {expected_rows:,}"
        )
    return files, rows, nbytes


def main():
    argv = [a for a in sys.argv[1:]]
    workers = _default_workers()
    out = []
    i = 0
    while i < len(argv):
        if argv[i] in ("-j", "--workers"):
            workers = int(argv[i + 1]); i += 2; continue
        if argv[i].startswith("--workers="):
            workers = int(argv[i].split("=", 1)[1]); i += 1; continue
        out.append(argv[i]); i += 1
    if len(out) not in (2, 3):
        print(__doc__)
        return 1
    src, dst = out[0], out[1]
    codec = out[2] if len(out) == 3 else "lz4"
    if codec not in ("none", "lz4", "zstd"):
        print(f"ERROR: unknown codec {codec!r}")
        return 1
    zstd_level = 9 if codec == "zstd" else 0

    if not os.path.isdir(src):
        print(f"ERROR: source not found: {src}")
        return 1
    stale = [f for f in os.listdir(dst) if f.endswith(".skene")] if os.path.isdir(dst) else []
    if stale:
        print(f"ERROR: {dst} already holds {len(stale)} .skene file(s); rm -rf it first")
        return 1

    paths = sorted(os.path.join(src, f) for f in os.listdir(src) if f.endswith(".parquet"))
    if not paths:
        print(f"ERROR: no parquet files in {src}")
        return 1

    # Row counts come from the source footers up front, so output index ranges
    # can be reserved before any worker starts and no worker has to ask another
    # where its files begin.
    row_counts = [read_metadata(p).num_rows for p in paths]
    expected_total = sum(row_counts)

    tasks = []
    next_index = 0
    for chunk_paths, chunk_rows in _plan_chunks(paths, row_counts, workers):
        tasks.append((chunk_paths, dst, "hits", codec, zstd_level, next_index, chunk_rows))
        next_index += _output_files_for(chunk_rows)

    os.makedirs(dst, exist_ok=True)
    if len(tasks) == 1:
        results = [_convert_chunk(tasks[0])]
    else:
        with ProcessPoolExecutor(max_workers=len(tasks)) as pool:
            results = list(pool.map(_convert_chunk, tasks))

    files = sum(r[0] for r in results)
    rows = sum(r[1] for r in results)
    nbytes = sum(r[2] for r in results)
    if rows != expected_total:
        raise RuntimeError(f"wrote {rows:,} rows, sources hold {expected_total:,}")
    if files == 0:
        raise RuntimeError("no row groups read - refusing to write an empty table")
    print(f"codec={codec} workers={len(tasks)} files={files} rows={rows} bytes={nbytes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
