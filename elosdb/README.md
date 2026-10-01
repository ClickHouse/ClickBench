# elosdb — ClickBench submission

`elosdb` is a single-node analytical database: a C++ storage and execution engine
with its own column format, behind a server that speaks the PostgreSQL v3 wire
protocol. All 43 ClickBench queries are answered by the engine.

> It is a personal research / hobby / experiments project, published so this
> result can be reproduced — **not for production use**.

Results are in [`results/`](results/), one JSON per machine in ClickBench's own
format: every query's three tries, the load time and the data size. The totals, each
installed by `./install` from the release it pins for each architecture —
[`v0.1.9`](https://github.com/decster/elosdb/releases/tag/v0.1.9), on aarch64 and on x86_64:

| machine | release | load | data size | cold (sum of 43 first tries) | hot (sum of 43 best-of-rest) | concurrent QPS |
|---|---|---:|---:|---:|---:|---:|
| c8g.4xlarge (16 vCPU, 32 GiB) | v0.1.9 aarch64 | 43.82 s | 7,668,470,464 B | 30.18 s | 2.11 s | 10.97 |
| c8g.metal-48xl (192 vCPU, 384 GiB) | v0.1.9 aarch64 | 35.14 s | 7,668,470,469 B | 28.56 s | 0.89 s | 37.02 |
| c6a.4xlarge (16 vCPU, 32 GiB) | v0.1.9 x86_64 | 82.71 s | 7,668,470,506 B | 37.09 s | 6.19 s | 4.21 |

On the two-socket 48xl the server defaults to one NUMA node's 96 cores.
Cold is the first try after the server was restarted and the OS page cache dropped;
it varies noticeably between instances of the same machine type, hot much less.

## Running it

From this directory:

    ./install        # downloads one file, verifies its sha256, installs psql
    ./benchmark.sh   # ClickBench's own driver

`install` compiles nothing. It fetches one statically-linked executable from
[github.com/decster/elosdb's releases](https://github.com/decster/elosdb/releases); the URL and
its sha256 are pinned in `install` itself, per architecture, and a mismatch is a refusal. Set
`ELOSDB_URL` (with `ELOSDB_SHA256`) to run a different build.

**One asset per architecture, and each names its core.** The aarch64 asset is built
`-mcpu=neoverse-v2` and refuses to start where SVE2 is absent; the x86_64 asset is built
`-march=x86-64-v3` (AVX2/FMA/BMI2, no AVX-512) and refuses on a CPU without those.
`install` selects by `uname -m`, and an architecture with no pinned asset is refused by
name. Each needs
`glibc >= 2.38` and nothing else — libstdc++ and libgcc are linked in, there is no shared library to place
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
