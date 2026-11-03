#!/usr/bin/env python3
"""Passes the lines of the dataset that are valid JSON objects from stdin to stdout,
byte for byte, and drops the others, reporting how many were dropped to stderr.

    gzip -dc file_0001.json.gz | python3 -I ../lib/filter-documents.py [--max-depth N]

The lines that are dropped:
- invalid JSON: a few documents longer than 64 KiB are split into two lines in the
  dataset (about 6 per 10 million documents), sometimes in the middle of a UTF-8
  character, so that the lines are not valid UTF-8 either;
- with --max-depth N, the documents nested deeper than N levels, for the systems that
  can't store them (MongoDB's BSON allows 100 levels; file 178 of the dataset has
  documents nested 2163 levels deep).
"""

import argparse
import json
import sys


def depth(value):
    """The nesting depth of a JSON value: 1 for an object or array of scalars.
    Iterative, because the depth can exceed Python's recursion limit."""
    best = 0
    stack = [(value, 1)]
    while stack:
        item, level = stack.pop()
        if isinstance(item, dict):
            best = max(best, level)
            stack.extend((child, level + 1) for child in item.values())
        elif isinstance(item, list):
            best = max(best, level)
            stack.extend((child, level + 1) for child in item)
    return best


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--max-depth", type=int, default=0, help="drop the documents nested deeper (0: no limit)")
    args = parser.parse_args()

    out = sys.stdout.buffer
    invalid = too_deep = 0
    for line in sys.stdin.buffer:
        try:
            # json.loads decodes bytes as strict UTF-8.
            document = json.loads(line)
        except (ValueError, RecursionError):
            invalid += 1
            continue
        if not isinstance(document, dict):
            invalid += 1
            continue
        # Counting the brackets is cheap; the exact depth is computed only if it may exceed the limit.
        if args.max_depth and line.count(b"{") + line.count(b"[") > args.max_depth and depth(document) > args.max_depth:
            too_deep += 1
            continue
        out.write(line)

    if invalid:
        print(f"load: skipped {invalid} invalid lines", file=sys.stderr)
    if too_deep:
        print(f"load: skipped {too_deep} documents nested deeper than {args.max_depth} levels", file=sys.stderr)


if __name__ == "__main__":
    main()
