#!/usr/bin/env python3
# Loads NDJSON from stdin into the index `hits` with the _bulk API: batches of
# 10000 documents, with several requests in flight. The documents that are
# rejected because of back pressure (HTTP 429) are sent again; any other
# rejection fails the load.
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from itertools import islice

URL = "http://localhost:9200/hits/_bulk"
BATCH = 10000
SENDERS = 8
ACTION = b'{"index":{}}\n'


def post(body):
    req = urllib.request.Request(URL, data=body, method="POST",
                                 headers={"Content-Type": "application/x-ndjson"})
    with urllib.request.urlopen(req, timeout=900) as resp:
        return json.loads(resp.read())


def send(lines):
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
            return
        retry = []
        for line, item in zip(lines, result["items"]):
            status = item["index"]["status"]
            if status == 429:
                retry.append(line)
            elif status >= 300:
                raise RuntimeError(f"bulk-load: rejected document: {json.dumps(item['index'].get('error'))[:2000]}")
        lines = retry
        time.sleep(min(30, 1 + attempt))
    raise RuntimeError("bulk-load: too many retries")


def main():
    sent = 0
    started = time.time()
    with ThreadPoolExecutor(SENDERS) as pool:
        pending = []
        while True:
            lines = list(islice(sys.stdin.buffer, BATCH))
            if not lines:
                break
            if not lines[-1].endswith(b"\n"):
                lines[-1] += b"\n"
            pending.append(pool.submit(send, lines))
            sent += len(lines)
            # Bound the memory: wait for the oldest batches.
            while len(pending) > 2 * SENDERS:
                pending.pop(0).result()
            if sent % 1000000 == 0:
                print(f"bulk-load: {sent} documents, {time.time() - started:.0f} s", file=sys.stderr)
        for p in pending:
            p.result()
    print(f"bulk-load: {sent} documents sent", file=sys.stderr)


main()
