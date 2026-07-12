pgrust is a rewrite of PostgreSQL in Rust targeting compatibility with
Postgres 18.3: https://github.com/malisper/pgrust

It runs from the official Docker image (`malisper/pgrust:v0.1`), which is a
drop-in replacement for the official `postgres` image. The Docker entrypoint
applies the settings the upstream README requires (`io_method=sync`,
`max_stack_depth=60000`, enlarged stack limits); no further tuning is done.

The table schema and queries are identical to the `postgresql` entry.

### Data loading workaround

pgrust v0.1 has a COPY input-buffer bug: encoding verification fails whenever
the 64 KiB raw-buffer refill boundary falls inside a multi-byte UTF-8
character, so `COPY hits FROM 'hits.tsv'` rejects the (valid UTF-8) dataset
with `invalid byte sequence for encoding "UTF8"`. The client-side `\copy`
path fails the same way, and `ENCODING 'SQL_ASCII'` does not help, because
the bug is in the buffer bookkeeping rather than in the verifier proper.
Minimal reproducer: COPY of any file larger than 64 KiB consisting of mostly
multi-byte characters (e.g. 3000 repetitions of a Cyrillic line) fails on the
first buffer refill.

Inputs of at most 64 KiB are processed in a single buffer fill and are
unaffected, so `load` splits the TSV into line-aligned <=64 KiB pieces
(`split -C 64k`) and loads each with its own COPY statement in a single
session and transaction. The data is not modified. The per-statement overhead
is about 5 ms, which adds roughly an hour to the load of the full dataset
compared to a hypothetical single COPY.
