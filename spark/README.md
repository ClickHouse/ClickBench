This README includes info on configuring Apache Spark for ClickBench.

## Notes

- 29 query with `REGEXP_REPLACE` is changed: `\1` is replaced with `$1` since Spark here follows Java’s regex syntax. In Java, backreferences in replacement strings use `$1`, `$2`, etc.
- `EventTime` and `EventDate` columns are transformed (see [#7](https://github.com/ClickHouse/ClickBench/issues/7) issue for details).
