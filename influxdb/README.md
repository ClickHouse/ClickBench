# InfluxDB

This entry uses [InfluxDB 3 Core](https://docs.influxdata.com/influxdb3/core/), the open-source SQL-capable
release of InfluxDB. The query engine is Apache DataFusion, the storage is local Parquet.

## Caveats

InfluxDB is a time-series database, not a general analytical database, so loading a flat 100M-row
analytical dataset into it stretches the data model:

1. **No bulk CSV/Parquet import.** The only ingestion path is line protocol over HTTP
   (`/api/v3/write_lp`). `load.py` streams `hits.tsv`, converts each row to a line-protocol point, and
   POSTs in batches. The conversion + ingest is the dominant cost of the load phase and is much slower
   than e.g. Postgres `\copy` or DuckDB `COPY FROM`.

2. **Required unique timestamp.** Line protocol merges points that share `(measurement, tags, timestamp)`,
   so to preserve all rows we use the row index as the line protocol timestamp (in nanoseconds, offset
   from a fixed 2020-01-01 epoch). The original `EventTime` is stored as a regular string field and used
   by the queries.

3. **No tags, all fields.** Tags are indexed at ingest time; for a wide flat schema the indexing cost
   is prohibitive. Every column is written as a field instead. Numeric columns use the integer
   line-protocol type (`...i`); string and date/time columns are written as strings.

4. **Query compatibility.** Most ClickBench queries run unchanged. Q19 and Q43 cast `EventTime` (stored
   as string) to a `TIMESTAMP` for `extract(minute ...)` and `date_trunc('minute', ...)`. DataFusion
   folds unquoted identifiers to lowercase, so `load.py` writes column names in lowercase to keep the
   standard CamelCase queries portable.

## Run

```
./benchmark.sh
```

The server listens on port 8181, stores data under `./influxdb3-data`, and runs without authentication
(`--without-auth`) for the duration of the benchmark.
