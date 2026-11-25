# Rayforce

[Rayforce](https://github.com/RayforceDB/rayforce) is a zero-dependency
columnar analytics and graph engine written in C (MIT). Queries are
written in Rayfall, its Lisp-like query language, so `queries.sql` holds
43 Rayfall expressions rather than SQL.

## Install

`./install` builds the latest release from source with
`make release CC=gcc`, which works on both amd64 and aarch64.
`RAYFORCE_VERSION=vX.Y.Z ./install` pins a release.

## Data layout

`./load` streams `hits.parquet` into a compressed splayed table under
`./hits` with `.parquet.splayed`. Types follow
`../clickhouse/create.sql`; text columns are `SYM` (dictionary-encoded).
On machines with more RAM than the Parquet file the dictionaries share
one `.sym` file, otherwise each text column gets its own compressed
symbol file.

## Server mode

`./start` runs `rayforce -p 5000 server.rfl`, which opens the table once
per start and writes `server.ready`; `./check` looks for that file and a
live server pid. `./query` sends the query over IPC and the server times
it with `timeit`, so the timing covers query execution only. The driver
restarts the server before every query, so cold runs are cold.

## Query adaptations

The queries are direct Rayfall translations of the SQL, checked against
`clickhouse-local` on a 2M-row subset. Differences: which rows a `LIMIT`
over ties returns; Q25 and Q27 also print `EventTime` (sorting happens
after projection); Q36 puts the aggregate before the derived keys; Q29
spells out `REGEXP_REPLACE` with string builtins and matches ClickHouse
on this dataset.
