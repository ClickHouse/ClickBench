> OrioleDB is a PostgreSQL extension that combines the advantages of both on-disk and in-memory engines. It uses PostgreSQL pluggable storage to increase performance and cut costs.

—[OrioleDB website](https://www.orioledb.com/)

**Note:**  

Updating statistics (`ANALYZE`) currently returns with the following error.

```
ERROR:  unexpected NULL detoast result
```

See https://github.com/orioledb/orioledb/issues/535