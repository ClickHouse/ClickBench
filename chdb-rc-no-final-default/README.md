Diagnostic copy of `chdb/` for a chdb-core release candidate. Not meant to be merged.

- `install` pins chdb-core to the `CORE_TAG` release instead of the latest one.
- `create.sql` explicitly disables automatic statistics and otherwise uses the default codec.
- The measured load does not run `OPTIMIZE TABLE ... FINAL`.
- After the measured flow, `profile` repeats the load with part_log and query_log enabled and
  prints a JSON report between `=== load_profile json ===` and `=== load_profile end ===`.
