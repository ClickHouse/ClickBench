## Spark with Velox

Vanilla Apache Spark plus the [Velox](https://velox-lib.io/) C++ vectorised
execution engine. Velox is integrated into Spark via Apache Gluten's Velox
backend, which offloads the physical plan from Spark's JVM-side Tungsten
engine to Velox running natively.

Compared with `spark-gluten/`, this entry pins the Gluten backend to
`velox` explicitly via `spark.gluten.sql.columnar.backend.lib`, so the
intent of the benchmark is unambiguous (Gluten in principle also accepts
the ClickHouse backend).

Memory is split between Spark's JVM heap and Velox's off-heap pool; see
the configuration in `query.py`.

### Limitations

Apache Gluten only ships pre-built Velox bundles for `linux_amd64`. On
ARM hosts the bundle has to be compiled from source — see the [Gluten
build guide](https://gluten.apache.org/docs/getting-started/build-guide/).
