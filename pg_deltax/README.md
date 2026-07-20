# DeltaX (δx)

DeltaX (δx) is an open-source (Apache 2.0) PostgreSQL extension offering
compression and columnar storage for time-series data. It stores the
compressed columnar data in regular Postgres tables, so features like
physical/logical replication, crash recovery, backups, and pg_dump work as
for any other Postgres table.

- [GitHub](https://github.com/xataio/deltax)
- [Homepage](https://xata.io)

## Running

On a `c6a.4xlarge` instance (Ubuntu 24.04, 500GB gp2):

```bash
git clone https://github.com/ClickHouse/ClickBench
cd ClickBench/pg_deltax
./benchmark.sh
```
