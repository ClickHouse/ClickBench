# DeltaX (δx)

DeltaX (δx) is an open-source (Apache 2.0) PostgreSQL extension offering
compression and columnar storage for time-series data. It stores the
compressed columnar data in regular Postgres tables, so features like
physical/logical replication, crash recovery, backups, and pg_dump work as
for any other Postgres table.

- [GitHub](https://github.com/xataio/deltax)
- [Homepage](https://xata.io)
- [PGDG-layout RPM build config (`pgrx-rpm-builder`)](https://github.com/suleymanngulter/pgrx-rpm-builder)

## Running

On a `c6a.4xlarge` instance (Ubuntu 24.04, 500GB gp2):

```bash
git clone https://github.com/ClickHouse/ClickBench
cd ClickBench/pg_deltax
./benchmark.sh
```

On `x86_64`, `./install` runs an `almalinux:9` container (`--network host` and
host-mounted data/socket directories) with official PGDG `postgresql18-server`
plus a SHA-256-verified third-party RPM for `pg_deltax` (`0.2.1` @ `33151a6`,
built with a PGDG-layout `/usr/pgsql-18` spec, not an official PGDG package).
Set `PG_DELTAX_BUILD_FROM_SOURCE=1` to compile from source instead (used
automatically on `aarch64`).
