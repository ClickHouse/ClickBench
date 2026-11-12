#!/usr/bin/env python3
"""Hands the queries over from the launcher to the machines, through the
results sink (sink.data on play.clickhouse.com), where the machines already
send their results.

  payload.py make <group> <system> <queries.json> <translated.json> <row.json>
      Writes the row to insert into the sink, and prints its hash.
  payload.py fetch <sink url> <group> <system> <hash> <dir>
      Finds the row with the hash and writes <dir>/queries.json and
      <dir>/translated.json.

Anyone can insert into the sink, so the machine takes only the row whose data
has the hash that the launcher put into the user data of the machine.
"""

import base64
import gzip
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request


def make(group, system, queries_file, translated_file, out):
    with open(queries_file) as f:
        queries = json.load(f)
    with open(translated_file) as f:
        translated = json.load(f)
    data = base64.b64encode(gzip.compress(json.dumps(
        {"queries": queries, "translated": translated}, ensure_ascii=False).encode(), mtime=0)).decode()
    with open(out, "w") as f:
        json.dump({"kind": "random-benchmark-payload", "group": group, "system": system, "data": data}, f)
    print(hashlib.sha256(data.encode()).hexdigest())


def fetch(url, group, system, digest, out):
    query = f"""SELECT JSONExtractString(content, 'data') FROM sink.data
        WHERE time >= now() - INTERVAL 7 DAY
          AND JSONExtractString(content, 'kind') = 'random-benchmark-payload'
          AND JSONExtractString(content, 'group') = '{group}'
          AND JSONExtractString(content, 'system') = '{system}'
        FORMAT TSVRaw"""
    for attempt in range(30):
        with urllib.request.urlopen(url + "&query=" + urllib.parse.quote(query), timeout=60) as response:
            rows = response.read().decode().split("\n")
        for data in rows:
            if data and hashlib.sha256(data.encode()).hexdigest() == digest:
                payload = json.loads(gzip.decompress(base64.b64decode(data)))
                os.makedirs(out, exist_ok=True)
                for name in ("queries", "translated"):
                    with open(os.path.join(out, name + ".json"), "w") as f:
                        json.dump(payload[name], f, indent=1, ensure_ascii=False)
                return
        print(f"payload: not found yet (attempt {attempt + 1})", file=sys.stderr)
        time.sleep(20)
    sys.exit("payload: no row with the expected hash")


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "make":
        make(*sys.argv[2:])
    elif len(sys.argv) == 7 and sys.argv[1] == "fetch":
        fetch(*sys.argv[2:])
    else:
        sys.exit(__doc__)
