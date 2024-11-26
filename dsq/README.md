The tool looks non-functional.

Even the simplest query:
```
dsq hits.parquet "SELECT count(*) FROM {}"
```
leads to OOM.
