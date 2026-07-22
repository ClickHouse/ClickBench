This entry runs Apache Spark with the [Apache Gluten](https://gluten.apache.org/) plugin configured to use the **ClickHouse backend** ('ch'). Gluten loads `libch.so` (a fork of ClickHouse v23.1) into the Spark executor JVM and runs the columnar physical plan natively through it. See also [`spark-gluten/`](../spark-gluten/) (Velox backend), [`spark-velox/`](../spark-velox/), and the [accelerators README](../spark/README-accelerators.md).

### Run

`./benchmark.sh` sets a few env vars and delegates to the shared driver
[`../lib/benchmark-common.sh`](../lib/benchmark-common.sh), which runs the
per-system scripts (`install`, `load`, `query`, ...) and prints the results in
the format collected by play.clickhouse.com. `./install` builds everything from
source (no pre-built bundle is published for the CH backend).

## Notes

### Build

The CH backend is not part of Apache Gluten's release tarball — only the Velox bundle is published. As a result `install` builds two things from source:

1. **`libch.so`** — built from [Kyligence/ClickHouse](https://github.com/Kyligence/ClickHouse) at the org/branch/commit pinned in `gluten/cpp-ch/clickhouse.version`. The build uses Clang 19 / cmake / ninja (Gluten v1.4.0's CH backend requires Clang 19). Its `extern-local-engine` module links against JNI **including AWT**, so `install` uses the full `openjdk-17-jdk` (not `-headless`, which omits `jawt.h`/`libjawt.so` and makes cmake fail with `Could NOT find JNI (missing: AWT)`).
2. **The Gluten Spark plugin** — built via Maven with `-Pbackends-clickhouse -Pspark-3.5 -Pscala-2.12`. JDK 8 is required at compile time (Gluten's POM); Spark itself runs under JDK 17 (see `./query`).

Building libch.so essentially compiles ClickHouse from source: it is **memory-hungry** (Gluten's docs note that 64 GB RAM is recommended). On a c6a.4xlarge (32 GB RAM) the compile may OOM; use c6a.8xlarge or larger for a clean run.

### Configuration

- `spark.gluten.sql.columnar.backend.lib=ch` selects the ClickHouse backend over Velox.
- `spark.gluten.sql.columnar.libpath=<libch.so>` points to the native library. Gluten's wrapper cmakes into `gluten/cpp-ch/build_ch`, which drives an inner ClickHouse cmake that builds `libch.so` under `gluten/cpp-ch/build/.../extern-local-engine/`; `install` globs for it under `cpp-ch/` and symlinks it as `libch.so` in the entry directory.
- Memory is split 50/50 between Spark heap and Gluten off-heap, identical to the Velox entry — the CH backend also runs off-heap via JNI.
- Queries use ClickHouse-style regex backreferences (`\1`) rather than Spark's `$1`, since the regex evaluation happens inside libch.so. See the discussion in [`spark-gluten/README.md`](../spark-gluten/README.md) and [Gluten issue #7545](https://github.com/apache/incubator-gluten/issues/7545).

### Links

- [Gluten ClickHouse-backend getting started](https://gluten.apache.org/docs/get-started/ClickHouse/).
- [Gluten release page](https://gluten.apache.org/downloads/) (Velox bundles only).
- [Kyligence/ClickHouse fork](https://github.com/Kyligence/ClickHouse) (the source of libch.so).
