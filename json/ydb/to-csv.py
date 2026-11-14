#!/usr/bin/env python3

"""
Usage: to-csv.py <file number> < NDJSON > CSV

Converts the lines of one dataset file to the CSV rows (file, line, data) of
the bluesky table: the primary key of a column table must be made of non-JSON
columns, and the position of the document in the dataset is a unique key.

A few lines in the dataset are not valid JSON (documents of more than 64 KiB
that were cut into two lines): they are skipped, the other lines are passed
unchanged, except that the escape sequence \\u0000 is removed, as for
PostgreSQL.
"""

import csv
import json
import sys

file_number = int(sys.argv[1])
out = csv.writer(sys.stdout, lineterminator="\n")
out.writerow(["file", "line", "data"])
skipped = 0
for line_number, line in enumerate(sys.stdin.buffer, start=1):
    try:
        valid = isinstance(json.loads(line), dict)
    except ValueError:
        valid = False
    if not valid:
        skipped += 1
        continue
    text = line.decode("utf-8").rstrip("\r\n").replace("\\u0000", "")
    out.writerow([file_number, line_number, text])
if skipped:
    print(f"load: skipped {skipped} invalid lines in file {file_number}", file=sys.stderr)
