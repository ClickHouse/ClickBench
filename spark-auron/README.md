This README includes info on configuring Apache Auron (formerly Blaze) for ClickBench. For additional details, please refer to [Auron's docs](https://auron.apache.org/) and [spark-accelerators README](../spark/README-accelerators.md).

### Run

As usual, benchmark can be run via `./benchmark.sh`. Additionally, users can provide machine spec like `./benchmark.sh c6a.8xlarge` so script saves it in relevant file.

## Notes

### Debug

- To find all unsupported queries from `log.txt`:
```
>>> grep -o 'expressions.*' log.txt | grep -v 'toprettystring' | grep -o ' .*' | sort | uniq -c

     45  cast(EventTime#4L as timestamp)
     12  cast(none#0L as timestamp)
    153  date_add(1970-01-01, EventDate#5)
     72  date_add(1970-01-01, none#0)
     24  date_add(1970-01-01, none#1)
     15  date_trunc(class org.apache.spark.sql.auron.NativeExprWrapper() dataType:StringType), ...)
     15  minute(class org.apache.spark.sql.auron.NativeExprWrapper() dataType:TimestampType), ...)
      9  regexp_replace(Referer#14, ^https?://(?:www.)?([^/]+)/.*$, $1, 1)
      6  regexp_replace(none#0, ^https?://(?:www.)?([^/]+)/.*$, $1, 1)
```

### Links

- Refer to Auron's [`pom.xml`](https://github.com/apache/auron/blob/v5.0.0/pom.xml) for exact _version compatibility_ between Auron, Spark, Scala, and Java.
- Download _pre-built JARs_ from the [Auron archives](https://auron.apache.org/archives).
- View an example _Auron configuration_ in the [benchmarks documentation](https://auron.apache.org/documents/benchmarks.html#benchmark-configuration).

### Configuration

- As of version 5.0, Spark 3.5.5 is chosen since it's used for the `spark-3.5` shim (see `pom.xml`) and TPC-DS testing.
- Apache Auron was previously named [Blaze](https://github.com/apache/auron/issues/1168). This change occurred after version 5.0, so previous naming references (links, settings) still remain. These will be updated in the next version.
- In version 5.0, Auron generates extensive INFO logs (~55MB file after ~40 queries), which may impact system performance. This behavior will be manageable in next version and will require setting `spark.auron.native.log.level`.
- Auron's memory configuration follows the example from the [benchmark page](https://auron.apache.org/documents/benchmarks.html#benchmark-configuration).
