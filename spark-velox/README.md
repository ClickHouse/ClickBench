Spark + [Velox](https://velox-lib.io/) via [Apache Gluten](https://gluten.apache.org/). Velox is a C++ vectorised execution engine; the Gluten plugin offloads Spark Catalyst's physical plan to Velox.

This entry is functionally close to [`spark-gluten/`](../spark-gluten/) — the difference is that the Gluten backend is pinned to `velox` explicitly via `spark.gluten.sql.columnar.backend.lib`, so the benchmark name reflects the engine actually doing the work (Gluten can in principle also use the ClickHouse backend).

### Run

```
./benchmark.sh
```

Optionally pass a machine spec to tag the saved results: `./benchmark.sh c6a.8xlarge`.

### Notes

- Apache Gluten ships pre-built Velox bundles only for `linux_amd64`. ARM hosts have to build the bundle from source — see [Gluten's build guide](https://gluten.apache.org/docs/getting-started/build-guide/).
- Velox runs off-heap; the script splits available memory 50/50 between Spark's JVM heap and Gluten's native off-heap pool, matching [official guidance](https://apache.github.io/incubator-gluten/get-started/Velox.html#submit-the-spark-sql-job).
- See [spark-gluten/README.md](../spark-gluten/README.md) and [spark/README-accelerators.md](../spark/README-accelerators.md) for additional context.
