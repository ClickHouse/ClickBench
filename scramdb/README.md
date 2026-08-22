# ScramDB

PostgreSQL-wire-compatible UTAP database, run from its official Docker image
`scramdb/scramdb:cb`.

    bash benchmark.sh

Targets machines with >= 16 GB RAM; `install` warns and continues below that.

## Entries

- `scramdb` - CPU, product defaults (`tuned: no`)
- `scramdb-tuned` - CPU, buffered io plus measured execution knobs
  (`tuned: yes`)

## Config

`install` writes `scramdb-config.toml`, mounted over `/etc/scramdb/config.toml`.
Mounting replaces the image's own config wholesale, so this entry restates the
shipped file key for key: no performance knob is changed, and memory is sized
by the engine from detected RAM. Deviations: WAL archiving off (the shipped
image enables it for point-in-time recovery; a benchmark box does none, and
archived segments would count into `data_size`), and the UDF and GPU lanes
off (nothing beyond the benchmark runs).

`--privileged --ulimit memlock=-1:-1` are only needed if the `io_uring`
backend is selected; neither shipped config selects it.

## Load

`COPY`, `CHECKPOINT`, `ANALYZE`, all inside the timed window, so `load_time`
includes them.

The schema declares no primary key - ClickBench's schema does not ask for one
and no competitor entry declares one. `create.sql.with-pk` preserves the keyed
variant. Row order is the input file's.

## data_size

`sudo du -sb --exclude=scramvm_cache ./db`. The compiled-query cache is derived
from the queries, not the data.

## Known

Try 1 is not compile-cold: the compiled-query cache survives restarts. No
NUMA-aware scheduling, no huge pages.
