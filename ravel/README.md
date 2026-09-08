# Ravel

[Ravel](https://github.com/NOFireAI/ravel) is an object-storage-native telemetry
database. Logs, metrics and traces are ingested into immutable objects in
S3-compatible storage, which is the only durable backend: there is no local-disk
storage mode and no local state a restart depends on. ClickBench's `hits` table
is loaded as the logs signal, with each column declared as a typed attribute
column, and queried over SQL.

For this benchmark the object store is a single-node [MinIO](https://min.io)
that `./install` downloads, starts and provisions on the machine's own disk, so
the entry runs like the other local-disk systems in this repository and needs
no cloud account. Run it the usual way:

```sh
./benchmark.sh
```

## What this entry needs

Nothing from the operator. `./install` fetches a pinned MinIO release, verifies
it against its published checksum, generates a credential pair into a file
readable by the current user only (`minio/credentials.env`), starts MinIO on
loopback with its data directory under `minio/data`, creates the bucket, and
runs `ravel-cli store qualify` once, the bucket's one-time conformance check.
The first `./start` bootstraps the bucket's `sys/tenancy` marker to the unkeyed
tenant-hash derivation: the server's own default is the keyed derivation, which
refuses to start without a deployment key file, and this benchmark holds no
secret and needs a derivable prefix for `./data-size`.

Credentials reach MinIO and Ravel through the environment, never a command
line; `ravel-env.sh` reads them from the generated file. `./stop` stops the
database only. MinIO stays up across the driver's restart cycle and
`./minio-start` restarts it if it is ever found down, so the page-cache drop
before each cold run reaches MinIO's files the same way it reaches any
local-disk engine's.

To run the same scripts against another S3-compatible store, set
`RAVEL_S3_ENDPOINT`, `RAVEL_S3_BUCKET`, `RAVEL_S3_ACCESS_KEY` and
`RAVEL_S3_SECRET_KEY` before `./install`; a non-loopback endpoint skips the
MinIO setup. `RAVEL_S3_REGION` defaults to `us-east-1`.

Optional: `RAVEL_TENANT` (default `clickbench`), `RAVEL_SHARDS` (default 4,
must match between `./load` and `./start`), `RAVEL_VERSION` (default the
released version `./install` downloads), `RAVEL_REF` (build that ref from
source instead), `MINIO_RELEASE` (the pinned MinIO release).

## How the run is configured

`./install` downloads the released `ravel-server` and `ravel-cli` for the host
architecture and verifies them against the release's `SHA256SUMS`; those are the
binaries extracted from the signed container images, so what runs here is what
the published image runs. If the release is unreachable it falls back to
building the pinned ref from source with `--release`.

`./start` passes **no performance flags**. Since 0.13.0 the server resolves its
query budgets at startup: fetch concurrency from the core count, the read caches
and the two SQL memory ceilings from usable memory (`MemTotal`, capped by the
cgroup memory limit when it runs in a container), with a fixed segment cap and
engine deadline. Every resolved value and its source is logged on a
`performance default resolved` line in `server.log`; a published result should
record those lines, because they are the configuration the numbers were measured
at.

### What the cold figures measure here

The reference machine's disk is a 500 GB gp2 volume, which sustains about
256 MB/s. Ravel holds no data on local disk, so a cold run (server restarted,
page cache dropped) fetches what it needs from MinIO, and MinIO reads it from
that volume. Two properties of that path decide the stock entry's cold numbers:

- The stock fetch policy reads whole objects, so a statement that touches the
  table reads the entire 11.2 GB corpus. At the volume's rate that is about
  44 s per statement, whatever the statement computes; 41 of the 43 cold
  figures sit between 42 and 44 s for that reason.
- MinIO serves a ranged GET by reading every 1 MiB block the range touches, so
  a policy that fetches column blocks instead of whole objects (the tuned entry)
  saves wire bytes but not disk bytes in the same proportion. Measured on this
  corpus, a statement asking for 1.4 GB of ranges made MinIO read 5.7 GB from
  disk.

The same binary against real S3 on the same machine reads at 855 MB/s
sustained and is not subject to either effect; that configuration is kept in
the section below as reference material, since the benchmark's harness does not
run entries on real S3.

### The tuned entry

The `<machine>.tuned.json` result is the same harness with four server flags
passed through `RAVEL_TUNED_ARGS` in `./start`, plus the read cache's local-disk
tier enabled through `RAVEL_CACHE_DIR`:

```
RAVEL_TUNED_ARGS="--logs-fetch-policy latency-first --fetch-concurrency 256 --sql-max-query-bytes 12884901888 --cache-max-bytes 26323035750" RAVEL_CACHE_DIR=$PWD/cache ./benchmark.sh
```

`latency-first` is a named policy, not a tuning constant: it says spend
requests to save wall time, and resolves the byte quantities exactly as
`byte-minimal` does, so a logs read takes ranged reads wherever they save
bytes. It only pays off once fetch concurrency is raised with it, which is what
the second flag does (it sets the object-store GET permits, the SQL partition
count and the PromQL fan-out together). The third flag lifts the per-query
memory pool from the value derived on a 30 GB machine (about 8.2 GB) to 12 GiB,
which is what lets the widest `GROUP BY` in the set (q33) complete instead of
being refused. The trade this entry accepts is more object-store requests for
less cold wall-clock; on the reference corpus it moves about 5.3x the GET
requests of the stock entry.

The fourth flag sets the read cache to 26.3 GB (80% of this machine's memory)
so the whole dataset can stay resident between the three runs of a query.
Measured, it changes the tuned entry's totals by about 1%: with `latency-first`
a query reads ranged blocks rather than whole objects, and that working set
already fits the default 8.2 GB cache. It is kept because it makes the entry's
cache behaviour independent of the dataset size rather than incidental to it,
and because the disk tier is bounded by the same resolved ceiling, so at this
setting the whole corpus fits the tier. The stock entry is where the cache size
decides the result: its derived cache is 25% of memory (8.2 GB), sized under a
ten-connection load test where a larger cache left too little headroom for
query demand, and whole-object reads of this dataset do not fit in it, so the
stock warm runs re-fetch every object (served from MinIO's page cache on this
machine). ClickBench runs one query at a time, which is not that concurrent
window, so the larger cache is safe here and is presented as what it is: a
tuning for this benchmark's protocol, not a recommended default. One server
left running across the whole set at this cache size is out-of-memory killed at
q33 once the cache has filled from the earlier queries; the protocol's restart
before every query is what makes the setting safe here.

`RAVEL_CACHE_DIR` turns on the local-disk tier of the same read cache. It sits
on the same volume as MinIO, so it is not a faster disk; what it changes is the
read shape. An object the server has fetched once is on later cold runs read
from the tier at byte granularity instead of through MinIO's 1 MiB blocks, and
the tier survives a server restart, so a statement's cold run benefits from the
objects earlier statements touched. That is stated here because it is part of
what the tuned figures measure.

`./load` declares the typed attribute columns and then loads the Parquet file.
Object size is set at ingest by `--batch-rows`: one batch becomes one object per
involved shard, so 150,000 rows over 4 shards gives ~4 MB objects and roughly
2,600 objects for the 100M-row dataset. **There is no post-load step**: no
compaction, no catalog fold, no VACUUM equivalent, so the layout the queries
run against is the layout ingest produced.

`./data-size` reports the tenant's whole durable footprint in the bucket (data
objects, commit records, manifests, catalog snapshots), which is where all of
Ravel's state lives.

### Reference: the same binary on real S3

Measured on the same machine and corpus against an S3 bucket in the instance's
region, credentials from the instance role, the same true-cold protocol; not
reproducible by this harness and therefore not a results file. Cold and hot are
the sums over the 43 statements of the first and third run.

| configuration | cold | hot |
|---|---|---|
| stock, real S3 | 487 s | 449 s |
| stock, local MinIO (the results file) | 1,701 s | 184 s |
| tuned, real S3, no disk tier | 233 s | 146 s |
| tuned, local MinIO, no disk tier | 1,222 s | 81 s |
| tuned, local MinIO, disk tier (the results file) | 727 s | 82 s |

## Notes

- Queries go over the HTTP SQL endpoint on loopback, one process per query, the
  same shape as the other daemon entries.
- Ravel is a telemetry database rather than a general-purpose warehouse: the
  `hits` columns are modelled as typed attribute columns on log records, and
  every query states a time window covering the dataset because the SQL
  endpoint's window defaults to the last hour.
- The heaviest whole-table aggregates can exceed the derived per-query memory
  pool on a small instance and are reported as errors rather than being run
  with a raised limit; in the stock result that is q33.
- The stock entry's warm runs re-read every object. Ravel holds no data on
  local disk, so a warm run is served from the read cache or not at all, and
  the stock cache (25% of memory, 8.2 GB here) is smaller than this dataset;
  on this machine the re-read comes from MinIO's page cache. The tuned entry
  shows the same binary with a cache the dataset fits in.
