#!/usr/bin/env python3
# Loads one .json.gz file of the dataset into OpenSearch with the _bulk API.
#
#   bulk-load.py <file> <url> <index> <user> <password>
#
# The lines are sent unchanged, except the few lines that are not valid JSON
# objects (documents of more than 64 KiB that were cut into two lines), which
# are dropped. Prints "<documents sent> <documents rejected>" to stdout.
import base64
import gzip
import json
import ssl
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

BATCH = 5000
SENDERS = 4

path, url, index, user, password = sys.argv[1:6]
endpoint = f"{url}/{index}/_bulk"
auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
ACTION = b'{"index":{}}\n'


def post(body):
    req = urllib.request.Request(endpoint, data=body, method="POST", headers={
        "Content-Type": "application/x-ndjson", "Authorization": auth})
    with urllib.request.urlopen(req, context=ctx, timeout=600) as resp:
        return json.loads(resp.read())


def send(lines):
    """Sends a batch, retrying the documents rejected because of back
    pressure (429). Returns the number of documents rejected otherwise."""
    rejected = 0
    for attempt in range(100):
        body = b"".join(ACTION + line for line in lines)
        try:
            result = post(body)
        except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
            if isinstance(e, urllib.error.HTTPError) and e.code not in (429, 502, 503, 504):
                raise RuntimeError(f"bulk request failed: {e.code} {e.read()[:2000]!r}")
            print(f"bulk-load: {e}, retrying", file=sys.stderr)
            time.sleep(min(30, 1 + attempt))
            continue
        if not result.get("errors"):
            return rejected
        retry = []
        for line, item in zip(lines, result["items"]):
            status = item["index"]["status"]
            if status < 300:
                continue
            if status == 429:
                retry.append(line)
            else:
                rejected += 1
                if rejected <= 3:
                    print(f"bulk-load: rejected document: {json.dumps(item['index'].get('error'))[:1000]}",
                          file=sys.stderr)
        if not retry:
            return rejected
        lines = retry
        time.sleep(min(30, 1 + attempt))
    raise RuntimeError("bulk-load: too many retries")


def batches():
    skipped = 0
    batch = []
    with gzip.open(path, "rb") as f:
        for line in f:
            try:
                valid = isinstance(json.loads(line), dict)
            except ValueError:
                valid = False
            if not valid:
                skipped += 1
                continue
            if not line.endswith(b"\n"):
                line += b"\n"
            batch.append(line)
            if len(batch) >= BATCH:
                yield batch
                batch = []
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
        # Bound the memory: wait for the oldest batches.
        while len(pending) > 2 * SENDERS:
            rejected += pending.pop(0).result()
    for p in pending:
        rejected += p.result()
print(sent, rejected)
