# ClickBench — rayforce, 10M-row in-memory run

Scaled-down (10M-row) harness for iterating on rayforce ClickBench
performance without waiting for the full 100M load every change.

## Harness

| script | purpose |
|---|---|
| `bench_rf_mine.sh` | full 43 queries × 3 reps, min-of-3, in-memory `.csv.read` |
| `benchq.sh NN [NN…]` | load once, run a listed subset of queries with `REPS=N` reps |
| `perfq.sh NN [REPS]` | `perf record` one query, skipping the ~30 s load via `perf -D` |
| `capture_rf.sh` | run all 43 once, dump full REPL output for correctness inspection |
| `corr.sh` | fast 100K-row correctness pass over all 43 queries |
| `cmpq.sh qNN [qNN…]` | side-by-side rayforce vs reference 100K-row result for given queries |
| `bench_duck.sh` | reference timings on the same `hits.db` |

`q/q00.rfl … q42.rfl` mirror the ClickBench queries in rayforce's
expression syntax.  `schema.rfl` and `create.sql` describe the table.

## Data

`hits_h.csv` (10 M rows, ~8 GB) is the in-memory CSV; `hits.db` is the
matching reference database for the comparison timings.  Neither is
checked in — generate them locally.

## Results

`rf_min.txt` is the min-of-3 of the most recent run; `duck_min.txt`
the corresponding reference numbers.  Both are updated by the
respective harness scripts and are tracked so a clean rerun is
reproducible.
