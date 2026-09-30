# elosdb — ClickBench submission

`elosdb` is a single-node analytical database: a C++ storage and execution engine
with its own column format, behind a server that speaks the PostgreSQL v3 wire
protocol. All 43 ClickBench queries are answered by the engine.

> It is a personal research / hobby / experiments project, published so this
> result can be reproduced — **not for production use**.

Results are in [`results/`](results/), one JSON per machine in ClickBench's own
format: every query's three tries, the load time and the data size. The totals, for
`elosdb v0.1.7` installed from [its release](https://github.com/decster/elosdb/releases/tag/v0.1.7) by `./install`:

| machine | load | data size | cold (sum of 43 first tries) | hot (sum of 43 best-of-rest) | concurrent QPS |
|---|---:|---:|---:|---:|---:|
| c8g.4xlarge (16 vCPU, 32 GiB) | 43.85 s | 7,668,470,465 B | 30.08 s | 2.31 s | 8.15 |
| c8g.metal-48xl (192 vCPU, 384 GiB) | 34.73 s | 7,668,470,465 B | 29.68 s | 1.00 s | 31.17 |

On the two-socket 48xl the server defaults to one NUMA node's 96 cores.
Cold is the first try after the server was restarted and the OS page cache dropped;
it varies noticeably between instances of the same machine type, hot much less.

## Running it

From this directory:

    ./install        # downloads one file, verifies its sha256, installs psql
    ./benchmark.sh   # ClickBench's own driver

`install` compiles nothing. It fetches one statically-linked executable from
[github.com/decster/elosdb's releases](https://github.com/decster/elosdb/releases); the URL and
its sha256 are pinned in `install` itself and a mismatch is a refusal. Set
`ELOSDB_URL` (with `ELOSDB_SHA256`) to run a different build.

**aarch64 only**, and the artifact names its core: it is built `-mcpu=neoverse-v2`
and refuses to start where SVE2 is absent. It needs `glibc >= 2.38` and nothing
else — libstdc++ and libgcc are linked in, there is no shared library to place
beside it, and it exports no global dynamic symbols. The other requirement is a
`psql`, which `install` apt-gets.

## The scripts

| | |
|---|---|
| `install` | fetch + verify the binary; make sure there is a working psql |
| `start` | one server on 127.0.0.1:5432 — no tuning flags |
| `load` | `create.sql`, then one `COPY hits FROM 'hits.parquet'` |
| `query` | a statement in on stdin, psql's `\timing` out on stderr |
| `data-size` | `du -bs` of the store directory |
| `stop` | SIGTERM, then wait, so `drop_caches` finds nothing holding the store mapped |

`tuned: no` is a claim `start` has to keep, so its only flags are the port and the
data directory; every other setting is the binary's own default. `create.sql` is
[umbra's](../umbra/create.sql) column
list unchanged — no per-column encoding is declared, the encoder picks every layout
from the data — and `queries.sql` is umbra's unchanged. The store is
built inside the timed load window — nothing is cached or pre-computed.
