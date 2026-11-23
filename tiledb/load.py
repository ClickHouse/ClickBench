#!/usr/bin/env python3
"""Create the TileDB array `hits_array` and ingest hits.parquet into it.

The table is stored as one sparse TileDB array:

- dimensions: CounterID (int32), EventDate (datetime64[D]);
- attributes: the other 103 columns;
- duplicates are allowed, because several hits share the same
  (CounterID, EventDate) coordinates.

A sparse array is what makes filters work: a query condition on a sparse
array returns only the cells that satisfy it, while on a dense array the
result keeps the shape of the slice and the other cells come back as fill
values. The two dimensions are the columns the workload slices by.

The filters are those that `tiledb.from_pandas` applies when not told
otherwise: Zstandard with the default level on every attribute, dimension
and offsets buffer. Cell order, tile order and the data tile capacity are
the library defaults (row-major, 10000 cells).
"""

import os
import sys
import timeit

import numpy as np
import pyarrow as pa
import pyarrow.parquet as pq
import tiledb

ARRAY = os.path.abspath(os.environ.get("BENCH_TILEDB_ARRAY", "hits_array"))
PARQUET = os.environ.get("BENCH_TILEDB_PARQUET", "hits.parquet")

# Rows per write. Every write of a sparse array makes one immutable fragment,
# sorted by (CounterID, EventDate) inside, so fewer and larger writes mean
# fewer fragments to open and to search in every query. The upper bound is
# memory: a chunk is held as an Arrow table, as NumPy arrays (Python objects
# for the strings, the only form in which TileDB-Py takes variable-length
# values) and as the write buffers of TileDB at the same time, about 4 GB
# per million rows of this table.
CHUNK_ROWS = int(os.environ.get("BENCH_TILEDB_CHUNK_ROWS", "1000000"))

DIMENSIONS = ("CounterID", "EventDate")

# The athena-compatible hits.parquet stores the time columns as raw integers
# (seconds since the epoch for the timestamps, days since the epoch for the
# date) rather than as Parquet logical types.
SECONDS_COLUMNS = ("EventTime", "ClientEventTime", "LocalEventTime")
DAYS_COLUMNS = ("EventDate",)


def numpy_dtype(field):
    if field.name in SECONDS_COLUMNS:
        return np.dtype("datetime64[s]")
    if field.name in DAYS_COLUMNS:
        return np.dtype("datetime64[D]")
    if pa.types.is_string(field.type) or pa.types.is_large_string(field.type):
        return np.dtype(np.str_)
    return np.dtype(field.type.to_pandas_dtype())


def dimension_domain(dtype):
    if dtype.kind == "M":
        # The source column is an unsigned 16-bit number of days.
        return np.datetime64(0, "D"), np.datetime64(np.iinfo(np.uint16).max, "D")
    # The whole range of the type but its last value: TileDB requires the
    # number of values in the domain to fit into the unsigned counterpart
    # of the type.
    info = np.iinfo(dtype)
    return info.min, info.max - 1


def create_array(arrow_schema):
    zstd = tiledb.FilterList([tiledb.ZstdFilter()])
    dims = {}
    attrs = []
    for field in arrow_schema:
        dtype = numpy_dtype(field)
        if field.name in DIMENSIONS:
            dims[field.name] = tiledb.Dim(
                name=field.name,
                domain=dimension_domain(dtype),
                dtype=dtype,
                filters=zstd,
            )
        else:
            attrs.append(
                tiledb.Attr(
                    name=field.name,
                    dtype=dtype,
                    var=dtype.kind == "U",
                    filters=zstd,
                )
            )
    schema = tiledb.ArraySchema(
        domain=tiledb.Domain(*(dims[name] for name in DIMENSIONS)),
        attrs=attrs,
        sparse=True,
        allows_duplicates=True,
        offsets_filters=zstd,
    )
    tiledb.Array.create(ARRAY, schema)


def to_numpy(table):
    columns = {}
    for name in table.column_names:
        values = table.column(name).combine_chunks()
        if name in SECONDS_COLUMNS:
            columns[name] = values.to_numpy().astype("datetime64[s]")
        elif name in DAYS_COLUMNS:
            columns[name] = values.to_numpy().astype("datetime64[D]")
        else:
            columns[name] = values.to_numpy(zero_copy_only=False)
    return columns


def main():
    if tiledb.object_type(ARRAY) is not None:
        print(f"load: {ARRAY} already exists, remove it to load again", file=sys.stderr)
        return 1

    start = timeit.default_timer()
    parquet = pq.ParquetFile(PARQUET)
    create_array(parquet.schema_arrow)

    rows = 0
    buffered = []
    buffered_rows = 0

    with tiledb.open(ARRAY, "w") as array:

        def flush():
            nonlocal rows, buffered, buffered_rows
            if not buffered:
                return
            table = pa.Table.from_batches(buffered)
            buffered = []
            buffered_rows = 0
            columns = to_numpy(table)
            coordinates = tuple(columns.pop(name) for name in DIMENSIONS)
            array[coordinates] = columns
            rows += table.num_rows
            elapsed = timeit.default_timer() - start
            print(f"load: {rows} rows in {elapsed:.0f} s", file=sys.stderr, flush=True)

        for batch in parquet.iter_batches(batch_size=CHUNK_ROWS):
            buffered.append(batch)
            buffered_rows += batch.num_rows
            if buffered_rows >= CHUNK_ROWS:
                flush()
        flush()

    expected = parquet.metadata.num_rows
    stored = sum(fragment.cell_num for fragment in tiledb.FragmentInfoList(ARRAY))
    if stored != expected:
        print(f"load: {stored} cells stored, {expected} rows in {PARQUET}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
