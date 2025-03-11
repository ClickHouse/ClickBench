###pgpro_tam is an extensible table access method for vanilla Postgres

It supports multiple data formats, storage managers and execution engines.
More: https://hub.docker.com/r/innerlife/pgpro_tam

pgpro_tam extension allows to use different pluggable modules.

Data format modules used in tests:
1) Parquet
2) Feather (Apache Arrow file-based IPC)

Storage manager modules used in tests:
1) Local storage
2) Local storage with in-memory file mirroring

Execution engine modules used in tests:
1) DuckDB

For parquet the default compression is ZSTD3.
One of tests uses 'parallel' for loading. In case of inserting a data from one big file, the speed is far from maximum, but a deal is a deal. We do not split the file because it is not recommended by rules.
We also do not use fine tuning as it is not recommended. Tuning each column with own lightweight encoding would give better results.
Feather format is presented to share our experience. Using an uncompressed format gives gains on some queries, but on average it is worse than parquet.
