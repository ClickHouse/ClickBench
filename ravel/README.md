# Ravel

[Ravel](https://github.com/NOFireAI/ravel) is an object-storage-native telemetry
database. Logs, metrics and traces are ingested into immutable objects in
S3-compatible storage, which is the only durable backend: there is no local-disk
storage mode and no local state a restart depends on. ClickBench's `hits` table
is loaded as the logs signal, with each column declared as a typed attribute
column, and queried over SQL.

## What this entry needs

Unlike the other S3-using entries in this repository, which read the public
`hits` dataset in place, Ravel *writes* its own objects, so it needs a bucket it
can read and write.

- The bucket needs no preparation. `./install` qualifies it once, and the first
  `./start` bootstraps its `sys/tenancy` marker to the unkeyed (v1) tenant-hash
  derivation. The server's own default is the keyed derivation, which refuses to
  start without a deployment key file; this benchmark holds no secret and needs
  a derivable prefix for `./data-size`, so `./start` pins it unkeyed.
- `RAVEL_S3_BUCKET` (required): a bucket dedicated to this benchmark. Everything
  is written under a `t/<tenant hash>/` prefix, so a shared bucket is correct,
  but it is not a fair one: the server's startup cache warmup and its background
  catalog fold cover every tenant in the bucket, which spends memory during the
  load and CPU beside the timed statements. Measure in a bucket that holds
  nothing else.
- `RAVEL_S3_REGION` (default `us-east-1`).
- `RAVEL_CACHE_DIR` (default empty, meaning off): path for the read cache's
  local-disk tier. Off by default because on the reference machine it is
  slower than the store it caches. A `c6a.4xlarge` has no instance store, so
  its disk is a 500 GB gp2 volume measuring 286 MB/s sequential, while this
  server sustains 855 MB/s from S3 and peaks at 1,117 MB/s. Set it only where
  the disk is genuinely faster: an instance-store box (NVMe at multiple GB/s)
  or gp3 with provisioned throughput.
- Credentials: **none are configured**. The server and the CLI run with
  `--s3-auth instance-role` and fetch short-lived credentials from IMDSv2, so
  the VM's instance profile must allow, for that bucket:

  ```json
  {
    "Version": "2012-10-17",
    "Statement": [
      { "Effect": "Allow",
        "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
        "Resource": "arn:aws:s3:::YOUR_BUCKET" },
      { "Effect": "Allow",
        "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
        "Resource": "arn:aws:s3:::YOUR_BUCKET/*" }
    ]
  }
  ```

  Setting any inline credential (`RAVEL_S3_ACCESS_KEY` and friends) alongside
  the instance role is refused at startup rather than resolved by precedence,
  and `ravel-env.sh` scrubs those variables so an interactive shell's exports
  cannot silently turn the run into a static-key run.

Optional: `RAVEL_TENANT` (default `clickbench`), `RAVEL_SHARDS` (default 4,
must match between `./load` and `./start`), `RAVEL_VERSION` (default the
released version `./install` downloads), `RAVEL_REF` (build that ref from
source instead).

Run it the usual way:

```sh
RAVEL_S3_BUCKET=your-bucket RAVEL_S3_REGION=us-east-1 ./benchmark.sh
```

## How the run is configured

`./install` downloads the released `ravel-server` and `ravel-cli` for the host
architecture and verifies them against the release's `SHA256SUMS`; those are the
binaries extracted from the signed container images, so what runs here is what
the published image runs. If the release is unreachable it falls back to
building the pinned ref from source with `--release`. It then runs
`ravel-cli store qualify` once, which is the bucket's one-time conformance
check; the server refuses to start against a store that has never been
qualified. Qualification is setup for the bucket rather than dataset work, so it
sits outside the measured load window.

`./start` passes **no performance flags**. Since 0.13.0 the server resolves its
query budgets at startup: fetch concurrency from the core count, the read caches
and the two SQL memory ceilings from usable memory (`MemTotal`, capped by the
cgroup memory limit when it runs in a container), with a fixed segment cap and
engine deadline. Every resolved value and its source is logged on a
`performance default resolved` line in `server.log`; a published result should
record those lines, because they are the configuration the numbers were measured
at.

### The tuned entry

The `<machine>.tuned.json` result is the same harness with four server flags
passed through `RAVEL_TUNED_ARGS` in `./start`:

```
--logs-fetch-policy latency-first --fetch-concurrency 256 --sql-max-query-bytes 12884901888 --cache-max-bytes 26323035750
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
so the whole 11.7 GB dataset can stay resident between the three runs of a
query. Measured, it changes the tuned entry's totals by about 1%: with
`latency-first` a query reads ranged blocks rather than whole objects (q2
moves 1.9 GB instead of 11.7 GB), and that working set already fits the
default 8.2 GB cache, so the tuned warm runs were served from cache before the
flag. It is kept because it makes the entry's cache behaviour independent of
the dataset size rather than incidental to it. The stock entry is where the
cache size decides the result: its derived cache is 25% of memory (8.2 GB),
sized under a ten-connection load test where a larger cache left too little
headroom for query demand, and whole-object reads of this dataset do not fit
in it, so the stock warm runs re-fetch every object. ClickBench runs one query
at a time, which is not that concurrent window, so the larger cache is safe
here and is presented as what it is: a tuning for this benchmark's protocol,
not a recommended default. Measured on this machine, one server left running
across the whole set at this cache size is out-of-memory killed at q33 once
the cache has filled from the earlier queries; the protocol's restart before
every query is what makes the setting safe here. Reproduce it with:

```
RAVEL_TUNED_ARGS="--logs-fetch-policy latency-first --fetch-concurrency 256 --sql-max-query-bytes 12884901888 --cache-max-bytes 26323035750" ./benchmark.sh
```

`./load` declares the typed attribute columns and then loads the Parquet file.
Object size is set at ingest by `--batch-rows`: one batch becomes one object per
involved shard, so 150,000 rows over 4 shards gives ~4 MB objects and roughly
2,600 objects for the 100M-row dataset. **There is no post-load step** — no
compaction, no catalog fold, no VACUUM equivalent — so the layout the queries
run against is the layout ingest produced.

`./data-size` reports the tenant's whole durable footprint in the bucket (data
objects, commit records, manifests, catalog snapshots), which is where all of
Ravel's state lives. The local disk holds only the downloaded Parquet file and
the read cache.

## Notes

- Queries go over the HTTP SQL endpoint on loopback, one process per query, the
  same shape as the other daemon entries.
- Ravel is a telemetry database rather than a general-purpose warehouse: the
  `hits` columns are modelled as typed attribute columns on log records, and
  every query states a time window covering the dataset because the SQL
  endpoint's window defaults to the last hour.
- The heaviest whole-table aggregates can exceed the derived per-query memory
  pool on a small instance and are reported as errors rather than being run
  with a raised limit.
- The stock entry's warm runs are close to its cold runs. Ravel holds no data
  on local disk, so a warm run is served from the read cache or not at all,
  and the stock cache (25% of memory, 8.2 GB here) is smaller than this
  dataset (11.7 GB). Every warm run therefore re-reads the objects it needs
  from object storage. The tuned entry shows the same binary with a cache the
  dataset fits in.
