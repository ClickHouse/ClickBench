import gzip
import json
from itertools import islice

import requests

# Quickwit's _bulk endpoint accepts at most 10MB per request; keep batches
# small enough to stay under the limit comfortably.
BULK_SIZE = 2000
QW_URL = "http://localhost:7280/api/v1/_elastic/hits/_bulk"
TOTAL_RECORDS = 99997497

# Quickwit only supports the "create" action of the Elasticsearch bulk API.
ACTION_META_BYTES = (json.dumps({"create": {"_index": "hits"}}) + "\n").encode("utf-8")
REQUEST_TIMEOUT = 120


def build_body(docs):
    parts = []
    for doc in docs:
        parts.append(ACTION_META_BYTES)
        parts.append(doc.encode("utf-8") if isinstance(doc, str) else doc)
    return b"".join(parts)


def send_bulk(session, docs, batch_num):
    # Quickwit's bulk endpoint requires a Content-Length header, so we have to
    # buffer the body rather than streaming it.
    resp = session.post(QW_URL, data=build_body(docs), timeout=REQUEST_TIMEOUT)
    if resp.status_code >= 300:
        print(
            f"\nSent batch {batch_num} ({len(docs)} docs) - Warning: HTTP {resp.status_code}: {resp.text[:300]}"
        )
        return 0

    body = resp.json()
    if body.get("errors"):
        items = body.get("items", [])
        err = sum(1 for i in items if "error" in i.get("create", {}))
        if err:
            print(f"\nBatch {batch_num}: {err} item errors")

    return len(docs)


def main():
    total_docs = 0
    batch_num = 0

    with requests.Session() as session:
        session.headers.update({"Content-Type": "application/x-ndjson"})

        with gzip.open("hits.json.gz", mode="rt", encoding="utf-8") as f:
            print("Reading from hits.json.gz")
            while True:
                docs = list(islice(f, BULK_SIZE))
                if not docs:
                    break
                batch_num += 1
                total_docs += send_bulk(session, docs, batch_num)
                pct = (total_docs / TOTAL_RECORDS) * 100 if TOTAL_RECORDS else 0
                print(f" {pct:.2f}% ({total_docs}/{TOTAL_RECORDS})")

    print(f"\nTotal docs sent: {total_docs}")


if __name__ == "__main__":
    main()
