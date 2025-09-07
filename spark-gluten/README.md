This README includes info on configuring Apache Gluten for ClickBench. For additional details, please refer to [Gluten's docs](https://apache.github.io/incubator-gluten/get-started/Velox.html) and [spark-accelerators README](../spark/README-accelerators.md).

### Run

As usual, benchmark can be run via `./benchmark.sh`. Additionally, users can provide machine spec like `./benchmark.sh c6a.8xlarge` so script saves it in relevant file.

## Notes

### Links

- Check [here](https://gluten.apache.org/downloads/) for _pre-built jars_.
- Check [here](https://gluten.apache.org/#3-how-to-use) and [here](https://apache.github.io/incubator-gluten/get-started/Velox.html#submit-the-spark-sql-job) for _examples of Gluten configuration_.

### Configuration

- Spark 3.5.2 is used. [Documentation recommends 3.5.5](https://apache.github.io/incubator-gluten/get-started/Velox.html#prerequisite), but running queries with 3.5.5 leads to warnings like `WARN SparkShimProvider: Spark runtime version 3.5.5 is not matched with Gluten's fully tested version 3.5.2` and produces the following error:
```
An error occurred while calling o59.showString.
: java.lang.NoSuchMethodError: 'scala.collection.Seq org.apache.spark.sql.execution.PartitionedFileUtil$.splitFiles(org.apache.spark.sql.SparkSession, org.apache.spark.sql.execution.datasources.FileStatusWithMetadata, boolean, long, org.apache.spark.sql.catalyst.InternalRow)'
```
- While [documentation](https://gluten.apache.org/#3-how-to-use) recommends building Gluten from source,  pre-compiled JAR is used to [avoid out-of-memory compilation issues](https://apache.github.io/incubator-gluten/get-started/Velox.html#build-gluten-with-velox-backend) on smaller machines:
> Notes: Building Velox may fail caused by OOM. You can prevent this failure by adjusting NUM_THREADS (e.g., export NUM_THREADS=4) before building Gluten/Velox. The recommended minimal memory size is 64G.
- Gluten requires a __dedicated off-heap memory pool__. Memory is split 50/50 between Spark heap and Gluten off-heap, similar to  [official guidance](https://apache.github.io/incubator-gluten/get-started/Velox.html#submit-the-spark-sql-job).
- JVM option `-Dio.netty.tryReflectionSetAccessible=true` [is set](https://github.com/apache/incubator-gluten/issues/8207) to avoid `UnsupportedOperationException: sun.misc.Unsafe or java.nio.DirectByteBuffer.<init>(long, int) not available` error.
