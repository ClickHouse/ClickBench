# AvogadroDB: ClickBench submission

AvogadroDB is an embedded analytical database written in Rust: its own column
format and compression cascade on disk, with Apache DataFusion as the query
executor over that format. Today it ships as a Windows desktop application, a
command-line tool (`avogadrodb`, Windows and Linux) and a local server. This
entry uses the command-line tool: one process per query, nothing resident.

> The source is not public. The executable used here is published under an
> evaluation license (reproduce this benchmark, evaluate the engine; no
> redistribution, no production use), in
> [github.com/avogadrodb/avogadrodb-clickbench](https://github.com/avogadrodb/avogadrodb-clickbench).

Results are in [`results/`](results/), one JSON per machine in ClickBench's own
format. The contact for this entry is the author of the pull request.

## Running it

From this directory:

    ./install        # downloads one executable and verifies its sha256
    ./benchmark.sh   # ClickBench's own driver

`install` compiles nothing. It fetches one executable from the releases of the
repository above; the tag and its sha256 are pinned in `install` itself and a
mismatch is a refusal. Set `AVOGADRODB_URL` (with `AVOGADRODB_SHA256`) to run a
different build. The executable is built inside `manylinux_2_28`, on the x86-64
baseline (no AVX2 or newer instruction assumed), and needs glibc >= 2.28 and
nothing else: libc, libm, libdl, libpthread, libgcc_s and the loader.

## The scripts

| | |
|---|---|
| `install` | fetch and verify the executable; `avogadrodb version` as the smoke test |
| `load` | `avogadrodb load` from `hits.parquet` into `db/hits`, at the final compression level, inside the timed window; nothing is re-compacted or pre-computed afterwards |
| `query` | one statement in on stdin, the whole result out as CSV, the time in seconds on the last line of stderr |
| `data-size` | `du -bs` of the database directory |
| `start`, `stop` | nothing: embedded |

`tuned: no` is a claim the scripts keep: `load` and `query` pass no tuning flag;
every setting is the executable's own default. `create.sql` documents the load
(the engine takes no DDL; the schema is the parquet file's). `queries.sql` is the
`datafusion` entry's, unchanged, and `preludio.sql` (the AvogadroDB benchmark
harness's own prelude file, byte-identical, comments in Portuguese) is the same
type adaptation that entry makes in its VIEW (EventDate from uint16 days to
DATE), prefixed to every query as a CTE.

## The clock

`query` reports the time from the catalog being open to the result written and
flushed: planning, execution, decompression and output are inside; process start,
the root lock and opening the catalog are outside. It is the boundary of duckdb's
`.timer` and of datafusion-cli's `Elapsed`.
