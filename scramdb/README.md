# ScramDB

PostgreSQL-wire-compatible UTAP database, run from its official Docker image
`scramdb/scramdb:latest`.

    bash benchmark.sh

Targets machines with >= 16 GB RAM; `install` warns and continues below that.

## Entries

- `scramdb` - CPU, product defaults (`tuned: no`)
- `scramdb-tuned` - CPU, io_uring plus execution knobs (`tuned: yes`)

## Config

`install` writes `scramdb-config.toml`, mounted over `/etc/scramdb/config.toml`.
Mounting replaces the image's own config, so the shipped values are restated.
Memory is sized by the engine from detected RAM.

Deviations: compiled-query cache enlarged (sized from RAM, so nothing evicts),
WAL archiving off, UDF off, explicit `ANALYZE` in `./load` instead of the
background one, shorter shutdown drain.

`--privileged --ulimit memlock=-1:-1` are for io_uring.

## Load

`COPY`, `CHECKPOINT`, `ANALYZE`, all inside the timed window, so `load_time`
includes them.

The schema declares the same primary key the other entries order on; row order
is the input file's.

## data_size

`sudo du -sb --exclude=scramvm_cache ./db`. The compiled-query cache is derived
from the queries, not the data.

## Known

Try 1 is not compile-cold: the compiled-query cache survives restarts. No
NUMA-aware scheduling, no huge pages.
