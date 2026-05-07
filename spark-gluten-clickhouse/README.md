This entry runs Apache Spark with the [Apache Gluten](https://gluten.apache.org/) plugin configured to use the **ClickHouse backend** ('ch'). Gluten loads `libch.so` (a fork of ClickHouse v23.1) into the Spark executor JVM and runs the columnar physical plan natively through it. See also [`spark-gluten/`](../spark-gluten/) (Velox backend) and the [accelerators README](../spark/README-accelerators.md).

### Run

`./benchmark.sh` builds everything from source (no pre-built bundle is published for the CH backend) and then runs all 43 queries. Optional first argument is the machine spec, e.g. `./benchmark.sh c6a.8xlarge`.

## Notes

### Build

The CH backend is not part of Apache Gluten's release tarball — only the Velox bundle is published. As a result `benchmark.sh` builds two things from source:

1. **`libch.so`** — built from [Kyligence/ClickHouse](https://github.com/Kyligence/ClickHouse) at the branch pinned in `gluten/cpp-ch/clickhouse.version`. The build uses Clang 18 / cmake / ninja.
2. **The Gluten Spark plugin** — built via Maven with `-P backends-clickhouse,spark-3.5`. JDK 8 is required at compile time (Gluten's POM); Spark itself runs under JDK 17.

Building libch.so essentially compiles ClickHouse from source: it is **memory-hungry** (Gluten's docs note that 64 GB RAM is recommended). On a c6a.4xlarge (32 GB RAM) the compile may OOM; use c6a.8xlarge or larger for a clean run.

### Configuration

- `spark.gluten.sql.columnar.backend.lib=ch` selects the ClickHouse backend over Velox.
- `spark.gluten.sql.columnar.libpath=<libch.so>` points to the native library. The build location is `gluten/cpp-ch/build_ch/utils/extern-local-engine/libch.so`; `benchmark.sh` symlinks it as `libch.so` in the entry directory.
- Memory is split 50/50 between Spark heap and Gluten off-heap, identical to the Velox entry — the CH backend also runs off-heap via JNI.
- Queries use ClickHouse-style regex backreferences (`\1`) rather than Spark's `$1`, since the regex evaluation happens inside libch.so. See the discussion in [`spark-gluten/README.md`](../spark-gluten/README.md) and [Gluten issue #7545](https://github.com/apache/incubator-gluten/issues/7545).

### Links

- [Gluten ClickHouse-backend getting started](https://gluten.apache.org/docs/get-started/ClickHouse/).
- [Gluten release page](https://gluten.apache.org/downloads/) (Velox bundles only).
- [Kyligence/ClickHouse fork](https://github.com/Kyligence/ClickHouse) (the source of libch.so).
