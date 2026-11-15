# NostromoDB

Ported from the JSONBench pull request https://github.com/ClickHouse/JSONBench/pull/131.

NostromoDB is distributed as the Docker image `svilenmihaylov/nostromodb` (tag `latest`
only), a command-line tool over an embedded database. Every statement is a new container,
so there is no server; the hot runs reuse only the OS page cache.

- `load` imports the `.json.gz` files with `IMPORT ... OPTIONS {'NDJSON': true}`, one per
  file, without a table definition.
- `query` runs the statement with `PROFILE` and reports the optimization plus execution
  time printed by NostromoDB (`Optimization took ...`, `Execution took: ...`), so the
  start of the container is not counted.
- `version` reports the digest of the image, as the image has no version tag.
