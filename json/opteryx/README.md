# Opteryx

Ported from the JSONBench pull request https://github.com/ClickHouse/JSONBench/pull/135.

Opteryx (`opteryx-core` on PyPI) is an in-process engine that queries the NDJSON files in
place with `READ_JSONL(..., ignore_errors => true)`: there is no table, no schema and no
index. `load` only decompresses the `.json.gz` files to `/var/lib/opteryx/bluesky`, so the
load time is the decompression time, and the data size is the size of the decompressed
files.

As in the main ClickBench entry (`../../opteryx`), Opteryx runs as a long-lived query
server (`server.py`). The driver restarts it and drops the page cache before every query:
the first run is cold, the other two run in the same process. The runtime is measured by
the server (draining `execute_to_morsels`), as in the PR. There is no result cache.

`ignore_errors` skips the few documents that are not valid JSON (9,999,994 of 10m and
99,999,968 of 100m are read, as many as ClickHouse loads).
