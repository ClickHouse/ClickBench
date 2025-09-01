import requests
import json
import gzip
from itertools import islice

# Number of documents per bulk request
BULK_SIZE = 10000
ES_URL = "http://localhost:9200/_bulk"
INDEX = "hits"
TOTAL_RECORDS = 99997497

# Precompute action metadata line once
ACTION_META_BYTES = (json.dumps({"index": {"_index": INDEX}}) + "\n").encode("utf-8")
REQUEST_TIMEOUT = 30  # seconds


def bulk_stream(docs):
    for doc in docs:
        yield ACTION_META_BYTES
        yield doc


def send_bulk(session, docs, batch_num):
    resp = session.post(ES_URL, data=bulk_stream(docs), timeout=REQUEST_TIMEOUT)
    if resp.status_code >= 300:
        print(
            f"\nSent batch {batch_num} ({len(docs)} docs) - Warning: HTTP {resp.status_code}"
        )
        return 0

    body = resp.json()
    if body.get("errors"):
        items = body.get("items", [])
        err = sum(1 for i in items if "error" in i.get("index", {}))
        if err:
            print(f"\nBatch {batch_num}: {err} item errors")

    return len(docs)


def main():
    total_docs = 0
    batch_num = 0

    with requests.Session() as session:
        session.headers.update({"Content-Type": "application/x-ndjson"})

        # Read compressed NDJSON directly from hits.json.gz, decompressing on the fly
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
