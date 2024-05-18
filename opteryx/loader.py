"""
We're using Opteryx to read the data - it's not that it can't 
read the data in the provided format, but it can't use most of
it's IO optimizations unless the files are smaller.

This takes the paritioned files and redistributes the rows
amongst a larger set of smaller files.

Preparing the data for reading is our load phase so we will 
collect time and space statistics to attest in the benchmark.
"""

import glob
import os
import time

import opteryx

from pyarrow import parquet


ROWS_PER_FILE = 20_000


if __name__ == "__main__":
    start = time.monotonic_ns()
    dataset = opteryx.query("SELECT * FROM raw_hits;")

    for id, batch in enumerate(dataset.to_batches(ROWS_PER_FILE)):
        parquet.write_table(batch.arrow(), f"hits/file-{id}.parquet")
        print(".", end="", flush=True)
    print("\nTook", (time.monotonic_ns() - start) / 1e9, "seconds to rewrite files")

    size = 0
    for file in glob.glob("file*.parquet"):
        size += os.path.getsize(file)

    print(f"Files are {size} bytes")

        