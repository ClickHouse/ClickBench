For basic information, check the [spark-accelerators README](../spark/README-accelerators.md).

- To find all unsupported queries from log.txt (requires `spark.comet.explainFallback.enabled=True` and better set `spark.sql.debug.maxToStringFields` to arbitrary big number like `10000`):
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
- Comet requires dedicated memory allocation, which can be provided either through memoryOverhead or off-heap memory. The [documentation recommends](https://datafusion.apache.org/comet/user-guide/tuning.html#configuring-comet-memory-in-off-heap-mode) using off-heap memory, which is the approach used in ClickBench.
Therefore, we need to split memory between heap (for Spark) and off-heap (for Comet). For both TPC-H and TPC-DS benchmarks, Comet documentation suggests a 50/50 proportion
(see [here](https://datafusion.apache.org/comet/contributor-guide/benchmarking.html)). Seems that this allocation is appropriate to support fallback to Spark execution when Comet can't handle certain operations, which is also relevant for ClickBench.
- `spark.driver.extraClassPath` is set so Comet doesn't fail on some queries (check [here](https://datafusion.apache.org/comet/user-guide/installation.html#additional-configuration) for info).
- `spark.comet.regexp.allowIncompatible` is set to `True` to allow using incompatible regular expressions so Comet doesn't fall back to Spark (check [here](https://datafusion.apache.org/comet/user-guide/compatibility.html#regular-expressions) for info).
