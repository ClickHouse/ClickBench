This README includes info on configuring Apache Gluten for ClickBench. For additional details, please refer to [Gluten docs](https://gluten.apache.org/docs/), [spark-accelerators README](../spark/README-accelerators.md) and Gluten release notes.

### Run

As usual, benchmark can be run via `./benchmark.sh`. Additionally, users can provide machine spec like `./benchmark.sh c6a.8xlarge` so script saves it in relevant file.

### Tips
- To find hints on fallbacks/unsupported operators (requires running bench in debug mode):
```bash
>>> grep -i "gluten" log.txt | sed -e 's/^[ \t]*//' | sort | uniq -c

    ... messages indicating Gluten plugin usage/fallbacks ...
```
- Check [downloads](https://gluten.apache.org/downloads/) for prebuilt jars and Spark compatibility.
- Check [configuration](https://gluten.apache.org/docs/configuration/) for _basic Gluten configuration_.

### Configuration
- Gluten requires a __dedicated off-heap memory pool__. We split available memory between heap (for Spark) and off-heap (for Gluten). The scripts allocate ~70% of available RAM to Spark and then split it 50/50 between heap and off-heap, similar to TPC-* guidance.
- Key settings applied in `query.py` builder:
  - `spark.plugins=org.apache.gluten.GlutenPlugin`
  - `spark.shuffle.manager=org.apache.spark.shuffle.sort.ColumnarShuffleManager`
  - `spark.memory.offHeap.enabled=true`
  - `spark.memory.offHeap.size=<computed>`
- Jar handling: the downloaded bundle is used via `spark.jars` and `spark.driver.extraClassPath`.
