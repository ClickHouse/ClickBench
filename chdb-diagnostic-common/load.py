import json
import shutil
import sys
import time
from pathlib import Path

from chdb import dbapi


target = Path(sys.argv[1])
max_insert_threads = sys.argv[2]
compression_mode = sys.argv[3]

shutil.rmtree(target, ignore_errors=True)
started = time.perf_counter()
con = dbapi.connect(path=str(target))
cur = con.cursor()
try:
    create_sql = Path("../chdb/create.sql").read_text()
    if compression_mode == "lz4":
        create_sql = create_sql.rstrip().removesuffix(";")
        create_sql += (
            "\nSETTINGS default_compression_codec = 'LZ4', "
            "enable_adaptive_codec_selection = 0"
        )
    elif compression_mode != "default":
        raise ValueError(f"unknown compression mode: {compression_mode}")
    cur.execute(create_sql)
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
            sum(marks) AS marks,
            groupUniqArray(default_compression_codec) AS default_codecs
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
            "compression_mode": compression_mode,
            "seconds": round(elapsed, 6),
            "system_parts": stats,
        },
        separators=(",", ":"),
    )
)
