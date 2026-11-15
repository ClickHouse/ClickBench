This entry runs Apache Spark with the [Apache Gluten](https://gluten.apache.org/) plugin configured to use the **ClickHouse backend** ('ch'). Gluten loads `libch.so` (Kyligence's fork of ClickHouse, built as a library) into the Spark JVM and runs the columnar physical plan natively through it. See also [`spark-gluten/`](../spark-gluten/) (Velox backend), [`spark-velox/`](../spark-velox/), and the [accelerators README](../spark/README-accelerators.md).

### Run

`./benchmark.sh` sets a few env vars and delegates to the shared driver
[`../lib/benchmark-common.sh`](../lib/benchmark-common.sh), which runs the
per-system scripts (`install`, `load`, `query`, ...) and prints the results in
the format collected by play.clickhouse.com. `./install` builds everything from
source (no pre-built bundle is published for the CH backend).

## Notes

### Build

The CH backend is not part of Apache Gluten's release tarball — only the Velox bundle is published. Release tags also carry a ClickHouse fork that is years old, so `install` pins a commit of Gluten `main` (currently ClickHouse 25.12, Kyligence branch `rebase_ch/20260425-25.12.10.7`) and builds two things from source:

1. **`libch.so`** — built from [Kyligence/ClickHouse](https://github.com/Kyligence/ClickHouse) at the org/branch/commit pinned in `gluten/cpp-ch/clickhouse.version`, with Gluten's own wrapper (`ep/build-clickhouse/src/build-clickhouse.sh`), Clang 19, cmake and ninja. Its `extern-local-engine` module links against JNI **including AWT**, so `install` uses the full `openjdk-17-jdk` (not `-headless`). The build is a ThinLTO ClickHouse build: the final link alone needs tens of GB of RAM.
2. **The Gluten Spark plugin** — built via Maven with `-Pbackends-clickhouse -Pspark-3.5 -Pscala-2.12 -Pdelta` under JDK 8. The `delta` profile is required by the module's enforcer. `install` adds `Option.when` for Scala 2.12 to one Delta 3.3 source file that uses it.

### Configuration

- `spark.gluten.sql.columnar.backend.lib=ch` selects the ClickHouse backend, and `spark.gluten.sql.columnar.libpath` points to `libch.so`.
- `libch.so` is preloaded into the JVM with `LD_PRELOAD` (set in `query.py` before the JVM starts), as Gluten's own launcher does. It needs static TLS, which a lazy `dlopen` cannot get, and its jemalloc must replace `malloc` for the whole process.
- `spark.gluten.sql.enable.native.validation=false`: the CH backend has no native plan validator, and with validation on, every operator silently falls back to vanilla Spark. Gluten's own CH benchmarks and tests set it the same way.
- Gluten marks `delta-spark` as `provided`, but the CH backend registers Delta Lake data sources at startup, so `delta-spark` and `delta-storage` (downloaded by the Maven build) are added to the classpath.
- Memory: 70% of the available RAM, a quarter for the Spark heap and the rest off-heap, because the ClickHouse engine does nearly all the work off-heap and each task's memory limit is `off-heap / cores`.
- The queries are the same as in `spark-gluten/`, including Spark's `$1` backreference syntax in `REGEXP_REPLACE`: the backend translates Spark semantics.

### Links

- [Gluten ClickHouse-backend getting started](https://gluten.apache.org/docs/get-started/ClickHouse/).
- [Gluten release page](https://gluten.apache.org/downloads/) (Velox bundles only).
- [Kyligence/ClickHouse fork](https://github.com/Kyligence/ClickHouse) (the source of libch.so).
