#!/usr/bin/env python3
# Loads one .json.gz file of the dataset into the Manticore table with the
# HTTP /bulk endpoint, each document into the `data` JSON attribute.
#
#   bulk-load.py <file> <url> <table>
#
# The documents are embedded unchanged, except the few lines that are not
# valid JSON objects (documents of more than 64 KiB that were cut into two
# lines), which are dropped. Prints "<documents sent> <documents rejected>"
# to stdout.
import gzip
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BATCH_BYTES = 4 << 20
SENDERS = 2

path, url, table = sys.argv[1:4]
endpoint = f"{url}/bulk"
PREFIX = b'{"insert":{"table":"' + table.encode() + b'","doc":{"data":'
SUFFIX = b'}}}\n'
errors_printed = 0


def post(body):
    for attempt in range(30):
        req = urllib.request.Request(endpoint, data=body, method="POST",
                                     headers={"Content-Type": "application/x-ndjson"})
        try:
            with urllib.request.urlopen(req, timeout=600) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            # The response of a failed bulk request is a JSON document with
            # the error.
            payload = e.read()
            try:
                return json.loads(payload)
            except ValueError:
                raise RuntimeError(f"bulk request failed: {e.code} {payload[:2000]!r}")
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            print(f"bulk-load: {e}, retrying", file=sys.stderr)
            time.sleep(min(30, 1 + attempt))
    raise RuntimeError("bulk-load: too many retries")


def body_of(lines):
    return b"".join(PREFIX + line + SUFFIX for line in lines)


def send(lines):
    """Returns the number of rejected documents."""
    global errors_printed
    result = post(body_of(lines))
    if not result.get("errors"):
        return 0
    if len(lines) == 1:
        if errors_printed < 3:
            errors_printed += 1
            print(f"bulk-load: rejected document: {json.dumps(result)[:1000]}", file=sys.stderr)
        return 1
    # Find the documents that are rejected: send the batch in halves.
    half = len(lines) // 2
    return send(lines[:half]) + send(lines[half:])


def batches():
    skipped = 0
    batch = []
    size = 0
    with gzip.open(path, "rb") as f:
        for line in f:
            try:
                valid = isinstance(json.loads(line), dict)
            except ValueError:
                valid = False
            if not valid:
                skipped += 1
                continue
            line = line.rstrip(b"\r\n")
            batch.append(line)
            size += len(line)
            if size >= BATCH_BYTES:
                yield batch
                batch = []
                size = 0
    if batch:
        yield batch
    if skipped:
        print(f"bulk-load: {path}: skipped {skipped} invalid lines", file=sys.stderr)


sent = 0
rejected = 0
with ThreadPoolExecutor(SENDERS) as pool:
    pending = []
    for batch in batches():
        sent += len(batch)
        pending.append(pool.submit(send, batch))
        while len(pending) > 2 * SENDERS:
            rejected += pending.pop(0).result()
    for p in pending:
        rejected += p.result()
print(sent, rejected)
