# SlothDB

[SlothDB](https://github.com/SouravRoy-ETL/slothdb) is an embedded analytical
columnar SQL database written in C++20. It is invoked as a single-binary CLI
(`slothdb`) similar to `duckdb` and operates on a `.slothdb` database file.

The install script downloads a pinned prebuilt Linux x86-64 binary from the
upstream GitHub release. Only an `x86_64` Linux binary is published, so the
benchmark currently runs on x86-64 ClickBench machines (c6a.\*, c7a.\*); on
ARM hosts (c8g.\*) the binary will not execute.

The CLI has no built-in query timer, so `./query` wraps each invocation with
wall-clock measurement (`date +%s.%N`), the same approach used for systems
without internal timing (e.g. `presto`, `mongodb`).

SlothDB still has a few SQL gaps as of v0.2.6 (per upstream's `bench/clickbench/README.md`),
so some queries are expected to fail and be recorded as `null` in the
result row.
