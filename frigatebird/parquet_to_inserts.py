#!/usr/bin/env python3
"""Stream hits.parquet to stdout as batched INSERT statements for frigatebird.

Frigatebird only supports INSERT ... VALUES (no parquet/CSV import), so we
read the parquet via pyarrow record batches and emit one INSERT statement per
batch (each statement holds BATCH_ROWS rows).

The output is line-oriented (one INSERT per line) so the receiver — the
frigatebird REPL reading from stdin — can process statements as they arrive
without buffering the whole script in memory.
"""

from __future__ import annotations

import datetime as dt
import sys

import pyarrow.parquet as pq

PARQUET_PATH = "hits.parquet"
BATCH_ROWS = 5000

# Columns that frigatebird stores as Timestamp. The parquet has these as
# integer seconds-since-epoch (EventTime/ClientEventTime/LocalEventTime) or
# days-since-epoch (EventDate); we render them as 'YYYY-MM-DD HH:MM:SS'
# string literals that frigatebird parses via parse_datetime().
TIMESTAMP_SECS = {"EventTime", "ClientEventTime", "LocalEventTime"}
DATE_DAYS = {"EventDate"}


def format_value(name: str, value: object) -> str:
    if value is None:
        return "NULL"
    if name in TIMESTAMP_SECS:
        ts = dt.datetime(1970, 1, 1) + dt.timedelta(seconds=int(value))
        return "'" + ts.strftime("%Y-%m-%d %H:%M:%S") + "'"
    if name in DATE_DAYS:
        ts = dt.datetime(1970, 1, 1) + dt.timedelta(days=int(value))
        return "'" + ts.strftime("%Y-%m-%d") + "'"
    if isinstance(value, (int, bool)):
        if value is True:
            return "1"
        if value is False:
            return "0"
        # Frigatebird's INSERT planner rejects unary-minus literals
        # (UnaryOp{Minus, Number}); wrap negatives as quoted strings,
        # which the column-type coercion path parses back to i64.
        if value < 0:
            return "'" + str(value) + "'"
        return str(value)
    if isinstance(value, float):
        if value < 0:
            return "'" + repr(value) + "'"
        return repr(value)
    if isinstance(value, (bytes, bytearray)):
        value = value.decode("utf-8", errors="replace")
    s = str(value).replace("'", "''")
    return "'" + s + "'"


def main() -> int:
    pf = pq.ParquetFile(PARQUET_PATH)
    column_names = pf.schema_arrow.names
    columns_clause = ", ".join(column_names)
    header = "INSERT INTO hits (" + columns_clause + ") VALUES "

    out = sys.stdout
    write = out.write

    pending: list[str] = []

    def flush() -> None:
        if pending:
            write(header)
            write(",".join(pending))
            write("\n")
            pending.clear()

    for batch in pf.iter_batches(batch_size=BATCH_ROWS):
        cols = [batch.column(i).to_pylist() for i in range(batch.num_columns)]
        for row_idx in range(batch.num_rows):
            parts = [format_value(column_names[c], cols[c][row_idx]) for c in range(len(column_names))]
            pending.append("(" + ",".join(parts) + ")")
            if len(pending) >= BATCH_ROWS:
                flush()
    flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
