Experimental DuckDB plug-in for MariaDB, see
- https://github.com/MariaDB/duckdb-engine
- https://mariadb.org/mariadb-duckdb-a-new-playground-for-analytics-a-first-look-at-the-new-storage-engine/

The install takes MariaDB 11.4.13 from archive.mariadb.org and the `mariadb-plugin-duckdb` package from the release [v2.0.1](https://github.com/drrtuy/duckdb-engine/releases/tag/v2.0.1) of https://github.com/drrtuy/duckdb-engine (DuckDB v2.0.0 inside). The package is checked against a sha256 pinned in `install`. There are packages for amd64 only.
