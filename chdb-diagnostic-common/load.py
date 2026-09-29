import json
import shutil
import sys
import time
from pathlib import Path

from chdb import dbapi


target = Path(sys.argv[1])
max_insert_threads = sys.argv[2]

shutil.rmtree(target, ignore_errors=True)
started = time.perf_counter()
con = dbapi.connect(path=str(target))
cur = con.cursor()
try:
    cur.execute(Path("../chdb/create.sql").read_text())
    if max_insert_threads != "default":
        cur.execute(f"SET max_insert_threads = {int(max_insert_threads)}")
    cur.execute(Path("../chdb/insert.sql").read_text())
    cur.execute(
        """
        SELECT
            count() AS parts,
            sum(rows) AS rows,
            sum(bytes_on_disk) AS bytes_on_disk,
            sum(data_compressed_bytes) AS compressed_bytes,
            sum(data_uncompressed_bytes) AS uncompressed_bytes,
            sum(marks) AS marks
        FROM system.parts
        WHERE active AND database = 'clickbench' AND table = 'hits'
        """
    )
    stats_row = cur.fetchone()
    stats = (
        {column[0]: value for column, value in zip(cur.description, stats_row)}
        if stats_row is not None
        else None
    )
finally:
    cur.close()
    con.close()

elapsed = time.perf_counter() - started
print(
    "DIAG_LOAD "
    + json.dumps(
        {
            "data_dir": str(target),
            "max_insert_threads": max_insert_threads,
            "seconds": round(elapsed, 6),
            "system_parts": stats,
        },
        separators=(",", ":"),
    )
)
