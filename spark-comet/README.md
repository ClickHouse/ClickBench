This README includes info on configuring Comet for ClickBench. For additional details, please refer to [Comet's docs](https://datafusion.apache.org/comet/user-guide/overview.html), [spark-accelerators README](../spark/README-accelerators.md) and [issue](https://github.com/apache/datafusion-comet/issues/2035) discussing the results.

### Run

As usual, benchmark can be run via `./benchmark.sh`. Additionally, users can provide machine spec like `./benchmark.sh c6a.8xlarge` so script saves it in relevant file.

### Tips
- To find all unsupported queries from `log.txt` (requires running bench in debug mode):
```bash
>>> grep -P "\[COMET:" log.txt | sed -e 's/^[ \t]*//' | sort | uniq -c

     78 +-  GlobalLimit [COMET: GlobalLimit is not supported]
     18 +-  HashAggregate [COMET: Unsupported aggregation mode PartialMerge]
    123 +-  HashAggregate [COMET: distinct aggregates are not supported]
    ...
```
- Check [here](https://datafusion.apache.org/comet/user-guide/installation.html#supported-spark-versions) for _version compatibility_ between Spark and Comet.
- Check [here](https://datafusion.apache.org/comet/user-guide/installation.html#using-a-published-jar-file) for _links to Comet jar_.
- Check [here](https://datafusion.apache.org/comet/user-guide/installation.html#run-spark-shell-with-comet-enabled) for _basic Comet configuration_.

### Configuration
- Comet requires a __dedicated memory pool__, which can be allocated either through memoryOverhead or off-heap memory. The [documentation recommends](https://datafusion.apache.org/comet/user-guide/tuning.html#configuring-comet-memory-in-off-heap-mode) using off-heap memory, which is the approach used in ClickBench.
Therefore, we need to split available memory between heap (for Spark) and off-heap (for Comet). For both TPC-H and TPC-DS benchmarks, Comet documentation [suggests](https://datafusion.apache.org/comet/contributor-guide/benchmarking.html) a 50/50 split. This allocation appears to be chosen to support Spark execution as well — it happens when Comet can't handle certain operators, which is also relevant for ClickBench.
- `spark.driver.extraClassPath` is set to prevent Comet from failing on certain queries (check [docs](https://datafusion.apache.org/comet/user-guide/installation.html#additional-configuration) for details).
- `spark.comet.regexp.allowIncompatible=True` allows Comet to use incompatible regular expressions instead of falling back to Spark (check [docs](https://datafusion.apache.org/comet/user-guide/compatibility.html#regular-expressions) for details).
- `spark.comet.scan.allowIncompatible=True` allows Comet to use different parquet readers to prevent query failures (check [issue](https://github.com/apache/datafusion-comet/issues/2035#issuecomment-3090666597) for details). <br>
What happens here: `hits.parquet` contains `short` type columns, so Comet uses the `native_comet` reader for compatibility. However, this reader [doesn't work](https://github.com/apache/datafusion-comet/issues/2038) for some queries (e.g., query 40), causing Comet to fail. As a workaround, we can allow Comet to produce results incompatible with Spark, enabling it to use [other readers](https://datafusion.apache.org/comet/user-guide/compatibility.html#parquet-scans) and successfully execute these queries.
