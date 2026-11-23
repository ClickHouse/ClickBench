# Deepgreen DB

Deepgreen DB was a proprietary MPP data warehouse from Vitesse Data, Inc.: a
fork of Greenplum with the executor replaced. Where Greenplum interprets a
plan tree a tuple at a time, Deepgreen compiles the plan to machine code with
LLVM and runs it over batches — the vendor's pitch was a drop-in Greenplum
replacement that is several times faster on the same SQL, same catalog, same
`gpinitsystem` / `gpstart` / `gpfdist` tooling.

The build benchmarked here is **18.16**, revision `8ceb95e`, dated
2019-04-19. It reports itself as

```
PostgreSQL 8.3.23 (Greenplum Database 5.17.0+8ceb95e build ga)
Deepgreen DB 18.16 [rev 8ceb95e on 2019-04-19]
```

so it is Greenplum 5.17 underneath, which is PostgreSQL 8.3. It is the last
release the company published, and Vitesse Data has since gone away.

On top of the Greenplum base, the release notes and the vendor manual list:
`decimal64` / `decimal128` IEEE decimal types to replace `numeric`, a faster
regular-expression implementation, LZ4 and ZSTD table compression, a `PAX`
storage format, `LIMIT SAMPLE n ROWS|PERCENT`, `approximate_count_distinct`
(HLL), streaming-histogram aggregates, per-query hints, an external-data
framework called XDrive (Kafka, S3, HDFS, Gemfire, Elasticsearch), an
alternative interconnect called Deepmesh, and FPGA offload for scans. None of
those are used here; ClickBench runs plain SQL against a plain table.

## Caveats

Four, and the first two are why this entry looks different from its
Greenplum-family neighbours.

1. **The results are deliberately not published.** The licence you must
   accept to install the software contains a DeWitt clause. See below.
2. **The software is no longer distributed by its vendor.** `./install`
   recovers the installer from a Docker Hub image layer. See below.
3. **x86-64 only.** The only surviving build is `ubuntu16.x86_64`, so the
   ARM machines in the ClickBench matrix (`c8g.*`) cannot run this entry at
   all.
4. **This is a frozen 2019 binary.** It receives no fixes, and its PostgreSQL
   base is 8.3 (2008). Read any number it produces as "what this product did
   when it was last shipped", not as the state of the art of anything.

## Results are not published

Section 3.3 of the Vitesse Deepgreen DB 18.16 Software License Agreement,
which `./install` accepts on your behalf with `--accept-license`, reads:

> Customer's use of the Software shall be limited to use on a single Node for
> a period of thirty (30) days for EVALUATION purpose only. […] Customer
> agrees not to: […] (iii) disclose results of any benchmark tests related to
> the Software without VITESSE DATA's prior written consent.

That is a textbook [DeWitt clause](https://cube.dev/blog/dewitt-clause-or-can-you-benchmark-a-database),
and there is no longer anybody at Vitesse Data to give the written consent.
So this entry follows the ClickBench rule for results that cannot be
published — see *If The Results Cannot Be Published* in the top-level README,
and the `kdb` and `dolphindb` entries: the installation and reproduction
scripts are here in full, `.gitignore` keeps `results/` out of the
repository, and `./benchmark.sh` runs the whole thing unattended so anyone
can produce the numbers for themselves.

The same section 3.1 forbids redistributing the software, so nothing in this
directory ships any part of it; `./install` fetches it from the vendor's own
Docker Hub account.

## Where the software comes from

Every official download route is dead:

- `vitessedata.com` is a parked domain serving word salad. Its
  `products/open-source-greenplum/download/` page survives in the Wayback
  Machine, but the pages are JavaScript shells and no `.bin` was ever
  archived.
- The vendor's own setup scripts
  ([vitessedata/quicksetup](https://github.com/vitessedata/quicksetup))
  fetch `https://s3.amazonaws.com/vitessedata/download/deepgreendb.*.bin`.
  The bucket still exists and now answers `403` for every key.
- There are no GitHub releases on any `vitessedata` repository.

What does survive is `vitessedata/deepgreen-ml` on Docker Hub, an
FPGA/machine-learning demo image the vendor published in May 2019. Its build
ran `quicksetup/u16.alveo/01_download.sh`, so one of its layers contains the
installer verbatim at
`home/mluser/quicksetup/u16.alveo/deepgreendb.18.16.ubuntu16.x86_64.190419.bin`.

`./install` pulls that single layer straight from the registry with `curl`
(an anonymous pull token, then the blob by digest — no `docker pull` of the
2.4 GB image), extracts the one file and checks its SHA-256. Layer digests
are content-addressed, so the bytes cannot change under us; the risk is Docker
Hub garbage-collecting the image, at which point the software is simply gone.
If you have the installer from elsewhere, set `DEEPGREEN_BIN_URL` and the
registry path is skipped.

## Why it runs in a container

The build targets Ubuntu 16.04, and Greenplum 5's management utilities
(`gpstart`, `gpstop`, `gpstate`, `gpinitsystem`'s host sorter) are **Python
2**. Ubuntu 24.04 has no `python2` package at all, and building CPython 2.7
against a modern toolchain is not something a benchmark script should do. So,
exactly like the `greengage` entry, everything runs inside a privileged
`ubuntu:22.04` container — the newest Ubuntu that still ships `python2` — and
`start`, `stop`, `check`, `load`, `query` and `data-size` `docker exec` into
it. The utilities invoke a bare `python`, so `./install` also drops a
`/usr/local/bin/python` → `python2` symlink; without it `gpinitsystem` dies
with `/usr/bin/env: 'python': No such file` halfway through building the
master.

The benchmark directory is bind-mounted into the container at
`/mnt/clickbench`. That is a deliberate difference from `warehousepg` and
`greengage`, which copy `hits.tsv` into the container: at 75 GB the copy
costs a second full-size write and 75 GB of extra disk, and gpfdist can just
as well read the file where it already is.

### Two library sets

Deepgreen ships its own dependencies in `$GPHOME/lib` (OpenSSL 1.0.2,
libxml2, Xerces, ORCA, PostGIS, …) plus a second directory, `$GPHOME/lib2`,
holding the Ubuntu 16.04 *system* libraries it was linked against. Four
sonames the engine needs no longer exist on 22.04 —
`libldap_r-2.4.so.2` (OpenLDAP dropped the reentrant variant in 2.5),
`libtinfo.so.5`, `libicuuc.so.55` and `libreadline.so.6` — and each drags its
own 16.04 closure with it (Heimdal Kerberos, nettle 6, libidn 11, ICU 55).

`./install` therefore builds a third directory, `$GPHOME/lib-compat`, holding
a symlink to every `lib2` spare that the host does not already provide, and
puts it on `LD_LIBRARY_PATH` after `$GPHOME/lib`. Nineteen libraries end up
linked; everything else comes from the distribution. `lib2` also contains
Ubuntu 16.04's **glibc**, which must never be linked — `ld.so` comes from the
host and a 2.23 `libc.so.6` under a 2.35 loader does not work — so the glibc
core set is skipped explicitly rather than by hoping the host always provides
it.

### `sudo -H -u`, not `sudo -iu`

The neighbouring Greenplum entries reach the `gpadmin` account with
`sudo -iu gpadmin bash -lc '…'`. With `-i`, sudo builds a login-shell command
line by escaping and joining its arguments, which silently mangles any
multi-line script: a trailing `&` becomes `\&` and newlines become line
continuations, so the *next* line ends up as arguments to the previous
command. A `gpfdist` start followed by a readiness loop turns into
`sleep 3 psql -d postgres …` and fails with `sleep: invalid option -- 'd'`.
Dropping `-i` passes argv through untouched, and `bash -lc` still sources
`/etc/profile` and `~/.bash_profile`, so the environment is identical. The one
thing `-i` also did was `cd` to the home directory, which `gpinitsystem` needs
because it takes its config and host file as relative paths, so `./install`
does that explicitly.

## Schema and storage

`create.sql` is the Greenplum-family schema, unchanged except for one word:

```sql
with (appendonly=true,orientation=column,compresstype=zstd)
DISTRIBUTED BY (UserID);
CREATE INDEX hits_idx on hits using btree (CounterID, EventDate, UserID, EventTime, WatchID);
```

Greenplum 6 introduced `appendoptimized` as the preferred spelling and the
`greenplum` / `cloudberry` / `greengage` / `warehousepg` entries all use it.
Greenplum 5 only knows `appendonly`, and Deepgreen rejects the newer name
with `unrecognized parameter "appendoptimized"`. Everything else — the column
orientation, ZSTD compression, the distribution key, the composite btree
index, the `gpfdist` external table — is byte-identical to those entries, so
the numbers are comparable with them.

`compresstype=zstd` is one of Deepgreen's additions; stock Greenplum 5 offers
`zlib`, `quicklz` and `rle_type`. The accepted set here is
`zlib`, `zstd`, `quicklz`, `rle_type` and `lz4`.

**The PAX format is not used**, because there is no published way to ask for
it. The release notes announce it ("V18 adds a new storage format, PAX; on
SSD it is a high-performance, easy-to-manage format") and the binary is full
of `exx_appendonly_*_pax` symbols, but `orientation` accepts only `row` and
`column` (`invalid parameter value for "orientation": "pax"`), there is no
`pax` reloption, and `pg_settings` has no setting whose name contains `pax`.
Whatever selects it was never documented in anything the company left behind.

## Loading

`gpfdist` serving `/mnt/clickbench`, an external table over
`gpfdist://localhost:8080/hits.tsv`, and `INSERT INTO hits SELECT * FROM
hits_ext` — the same shape as `warehousepg` and `greengage`. This is how a
Greenplum cluster is meant to be loaded: each of the 14 segments pulls its
own slice in parallel, where `COPY` would funnel all 100M rows through the
coordinator. ClickBench's TSV is exactly PostgreSQL's `text` COPY format
(tab-separated, `\N` for null, backslash escapes), so `FORMAT 'TEXT'` needs
no options.

`./load` waits for gpfdist to bind port 8080 before issuing the `INSERT`.
Without the wait the external table scan can reach a gpfdist that has been
forked but has not listened yet, and the whole load fails immediately.

## Configuration

Everything is left at the vendor's defaults; `template.json` says
`"tuned": "no"` and means it. Two defaults are worth knowing, because both
differ from stock Greenplum 5:

- `vitesse.enable` is **on**. This is the switch for the compiled executor,
  i.e. the entire product. Nothing has to be turned on to get what Deepgreen
  is for.
- `optimizer` is **off**. Greenplum 5 ships with ORCA enabled; Deepgreen
  ships with it disabled and uses the PostgreSQL planner. The ORCA libraries
  are present (`libgpopt.so.3`, `libnaucrates.so.3`, version 3.27.1), so
  `SET optimizer = on` works and would make a reasonable `deepgreen-orca`
  entry, but it is not what the vendor chose to ship.

The cluster is 14 primary segments on one host with no mirrors, which is what
the other Greenplum-family entries use, sized for the reference c6a.4xlarge.
On a much larger or much smaller machine you will want to edit
`DATA_DIRECTORY` in `gpinitsystem_config`, exactly as you would for those
entries.

A third default matters on a small machine: **`statement_mem` is
1250 MB**, ten times stock Greenplum's 125 MB. That is a per-segment,
per-statement ceiling on operator memory, so a single high-cardinality
`GROUP BY` may claim up to 14 x 1250 MB before it starts spilling, and the
driver's concurrent-QPS phase runs ten such statements at once.
`gp_vmem_protect_limit` is left at Greenplum's own 8192 MB default, which on
a 14-segment single host is far above the machine's RAM and so will not stop
it. Nothing here is changed, because `tuned: no` means the product runs as it
ships; if a 32 GB machine runs out of memory, the knob is

```
gpconfig -c statement_mem -v 125MB && gpstop -u
```

and a run configured that way should be submitted as a separate entry.

## `data-size`

`du -bcs /data0` inside the container: the coordinator catalog, all 14
segments' append-optimized column files, their indexes and their write-ahead
logs. Nothing of the cluster lives outside `/data0`.

## What has been verified

Worth stating plainly, because the software cannot be obtained from its
vendor and the results are not published.

- The installer recovered from the Docker Hub layer is intact and installs:
  sha256
  `033aa54694d7580a10d3f1252fa3dd3f0cff85611bb6b88befd3df580875c72e`,
  606,927,562 bytes, self-extracting, `VERSION=18.16 REVDATE=2019-04-19`.
- On Ubuntu 22.04 with `lib-compat` in place, every ELF file under
  `$GPHOME/bin` and `$GPHOME/lib` resolves all of its dependencies, and
  `postgres`, `psql`, `gpfdist` and the bundled PyGreSQL/`gppylib` Python 2
  modules all run.
- `gpinitsystem` builds a working single-host cluster, `create.sql` applies,
  `gpfdist` loads a 1% sample of the dataset through the external table
  (`INSERT 0 1000765`, every row accounted for), and all 43 queries run
  without error.
- The harness's cold cycle works against it: `./stop` shuts the cluster down
  cleanly ("Database successfully shutdown with no errors reported"),
  `./check` then fails as it should, `./start` brings it back with the data
  intact, and `./data-size` reports a plausible figure.
- The query results were diffed against `clickhouse-local` on the same
  sample; see the next section.

### Query results

All 43 were compared against `clickhouse-local` running `clickhouse/queries.sql`
over the same 1% sample.

**26 match byte for byte**, once the reference's own TabSeparated escaping is
undone. (Q25, Q26 and Q27 look different at first: ClickHouse's TSV writer
escapes the apostrophe in `i\'ll`, psql does not. Same string.)

**Five — Q14, Q16, Q17, Q19, Q22 — return exactly the same rows in a
different order**, among rows with equal sort keys.

**Eight — Q23, Q24, Q31, Q32, Q33, Q36, Q40, Q41 — pick different tied rows.**
Each of these is `ORDER BY <count> ... LIMIT 10` over a sample where the cut
falls inside a run of equal counts (in Q32, Q33, Q40 and Q41 *every* group in
the sample has count 1, so any ten rows are correct). The multiset of sort-key
values returned is identical to the reference in all eight.

**Q18 has no `ORDER BY` at all** — `GROUP BY UserID, SearchPhrase LIMIT 10` —
so any ten groups satisfy it. Both sides return ten groups of one row.

**Three — Q3, Q4 and Q10 — differ in numeric precision, and this is a real
Deepgreen defect.** `avg()` goes through a double before it becomes the
`numeric` its type says it is, so it carries about 15 significant digits
instead of PostgreSQL's exact division. Minimal reproducer:

```sql
SELECT AVG(x) FROM (SELECT 2532976247401878033::bigint AS x
                    UNION ALL SELECT 2532976247401878035::bigint) t;
-- exact, and what PostgreSQL 18 answers: 2532976247401878034
-- Deepgreen DB 18.16:                     2532976247401880000
```

`pg_typeof` says `numeric` in both cases, and turning the compiled executor
off with `SET vitesse.enable = off` changes nothing, so this is in the
aggregate itself and not in the JIT. In ClickBench it shows up as
`AVG(ResolutionWidth)` printing `1513.9687409132` where the exact value is
`1513.9687409132014` (Q3, Q10), and in Q4's `AVG(UserID)`.

Q4 is worth a footnote of its own, because the *reference* is the one that is
wrong there. `AVG(UserID)` over `BIGINT` overflows a 64-bit accumulator on
this data, and ClickHouse wraps: it answers `-702352578971.0005` where the
exact average is `2532976247401878033.3586…`. Deepgreen answers
`2532976247401880000`, which is that value correct to 15 significant digits —
far closer to the truth than the reference it is being compared with.

The verification above was done on an aarch64 development machine, running
the x86-64 binaries under `qemu-user` inside a chroot of the same
`ubuntu:22.04` root filesystem the container uses. That exercises the
software and the SQL faithfully — it is the same binaries, the same libraries
and the same cluster topology — but it says nothing about performance, and it
is not the environment `./install` produces. A run on a real x86-64 machine
has not been done, because publishing what it produced would breach the
licence.
