Several Spark plugins and extensions claim to offer significantly better performance than vanilla Spark for analytical workloads.
They share common characteristics, which are documented here for convenience.

Currently implemented in ClickBench:
- [Apache Comet](https://datafusion.apache.org/comet/user-guide/overview.html) (`spark-comet` folder)

There are some considerations when working with these accelerators. Several have already been discussed [here](https://github.com/ClickHouse/ClickBench/issues/517). This README provides general guidance and may be supplemented by READMEs in individual engine folders.

### General

Some of these backends set goal to provide performance improvements with no _code rewrites_. Therefore, an objective is to run the "same Spark" with minimal modifications (except for setup and configuration adjustments). In practice, this means changes should be limited to `benchmark.sh` and `query.py`.

### Setting Up

- Java installation is still required as Spark handles all operations except computation (and sometimes computation as well).
- Spark version has to be selected from a supported list (versions are likely restricted for internal API compatibility). This list is typically available in the documentation.
The current approach is to use the "latest stable Spark version" for each engine.
- These engines utilize Spark's plugin/extension system, therefore represent a `.jar` file. The appropriate `.jar` (engine) version usually depend on the Spark version, Scala version, and other factors.

### Configuration

- Resource allocation should follow existing Spark configuration to provide results' fairness. While `cores` allocation is straightforward, memory needs to be divided between heap (for Spark) and off-heap/overhead (for engines). It's safe to base configuration on the documentation recommendations/examples.
- `SparkSession` configuration typically requires settings like `spark.jars`, `spark.plugins`, and other parameters to enable engines.
- Remember to disable debug mode (most engines can explain fallbacks to Spark) to avoid performance overhead.

### Queries

These engines typically don't support the complete set of Spark operators, functions, or expressions. In such cases, they usually fall back gracefully to Spark execution or, rarely, fail due to semantic differences between Spark and engines.

The standard approach is to use the default `queries.sql`. However, queries can be optionally rewritten for complete engine computation (see [here](https://github.com/ClickHouse/ClickBench/issues/517#issuecomment-3069121171) for discussion).
