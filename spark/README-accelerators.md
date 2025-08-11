Several Spark plugins and extensions claim to offer significantly better performance than vanilla Spark for analytical workloads, see the [discussion here](https://github.com/ClickHouse/ClickBench/issues/517).

Currently available in ClickBench:
- [Apache Comet](https://datafusion.apache.org/comet/user-guide/overview.html) (folder `spark-comet/`)

There are some considerations when working with these accelerators.
This README provides general guidance and may be supplemented by READMEs in individual engine folders.

### General

- Engines under `spark-*/` share a base structure derived from `spark/`. Where possible, improvements or edits should be synced across all these engines - but with caution, as optimizations may not generalize.
- Some of these backends set goal to work without code rewrites. Therefore, it'd be great to run the "same Spark" with minimal modifications (except for setup and configuration adjustments).
- Although some accelerators aim to maintain compatibility with Spark (e.g., Comet), this is not critical in the context of ClickBench. Therefore, it is acceptable to disable such settings if they hinder engine performance (usually due to causing fallbacks or opting for less efficient but compatible implementations). For examples of such settings, refer to [Comet's docs](https://datafusion.apache.org/comet/user-guide/compatibility.html) or [Comet's README](../spark-comet/README.md#configuration).

### Setup

- Java installation is still required as Spark handles all operations except computation (and sometimes computation as well).
- There is a strong dependency between Spark, Java, Scala, and accelerator versions (likely for internal API compatibility). Version compatibility lists are typically available in each engine's documentation.

The current approach is to use the latest stable Spark version for each engine.

### Configuration

- Resource allocation should follow existing Spark configuration to ensure fair results comparison. While `cores` allocation is rather straightforward, memory needs to be divided between heap (for Spark) and off-heap/memoryOverhead (for engines). It should be safe to base configuration on the engine's documentation recommendations / examples. This also allows to not overfit on the benchmark.

### Queries

These engines typically don't support the complete set of Spark operators, functions, or expressions.
In such cases, they usually fall back gracefully to Spark execution or, rarely, fail due to semantic differences between them and Spark.

The standard approach is to use the default `queries.sql`.
However, queries can be optionally rewritten for complete engine computation (see [here](https://github.com/ClickHouse/ClickBench/issues/517#issuecomment-3069121171) for discussion).
