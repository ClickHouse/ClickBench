import json
import sys
import time

import chdb


data_dir, max_threads, query_file = sys.argv[1:]
query = open(query_file).read()
started = time.perf_counter()
error = None
try:
    sess = chdb.session.Session(data_dir)
    try:
        sess.query(
            f"USE clickbench; SET max_threads = {int(max_threads)}; {query}",
            "Null",
        )
    finally:
        sess.close()
except Exception as ex:  # The cross-version cells may be incompatible.
    error = f"{type(ex).__name__}: {ex}"

elapsed = time.perf_counter() - started
print(
    json.dumps(
        {"seconds": round(elapsed, 6), "error": error},
        separators=(",", ":"),
    )
)
