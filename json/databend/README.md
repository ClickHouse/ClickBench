# Databend

[Databend](https://github.com/databendlabs/databend), the latest stable release from GitHub (the release tarball with `databend-meta`, `databend-query` and the `bendsql` client), with the shipped configuration files. The only changes to them are the data and log directories, the built-in `root` user without a password, which is needed to connect, and `allow_insecure = true` in `[storage]`, without which `COPY` refuses to read the dataset from the local file system.

The documents are stored in a single `VARIANT` column (Databend's semi-structured type, a binary JSON representation that keeps the original documents). There is no cluster key and no index.

The data is loaded with `COPY INTO ... FROM (SELECT $1 FROM 'fs:///data/bluesky/') FILE_FORMAT = (TYPE = NDJSON)` directly from the `.json.gz` files, 32 files per `COPY`. `ON_ERROR = continue` skips the few lines of the dataset that are not valid JSON (documents of more than 64 KiB split into two lines), instead of losing the whole file.

The queries access the fields as `data['commit']['collection']::STRING`; the timestamps are `TO_TIMESTAMP(data['time_us']::INT64, 6)`. `DATE_DIFF` has no millisecond unit, so Q5 computes the activity span from the difference of the microsecond timestamps divided by 1000. Q2 uses the exact `COUNT(DISTINCT)`.

The runtime is the wall-clock time of the query measured by `bendsql --time=local`.
