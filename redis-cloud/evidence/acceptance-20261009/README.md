## PR154 full-data acceptance: October 9, 2026 Pacific

The merged [PR154](https://github.com/redis-field-engineering/redis-sql-trino/pull/154) fixes are independently validated on **99,997,497 rows** for Q24 and Q34. Q24 previously timed out at 1200 seconds on all attempts; Q34 previously failed with `MAX_AGGREGATE_GROUPS`. The unchanged SQL now produces correct results on all three attempts for both queries.

| Query purpose | Attempt 1 (s) | Attempt 2 (s) | Attempt 3 (s) | Best warm (s) | Correctness |
|---|---:|---:|---:|---:|---|
| Q24: Earliest 10 full rows whose URL contains google | 4.065388 | 3.933026 | 3.914345 | 3.914345 | 3 independent reference matches |
| Q34: Top 10 URLs by visit count | 75.063332 | 64.139660 | 61.687396 | 61.687396 | 3 independent reference matches |
| Q35: Same URL grouping with a constant column (control) | 79.409368 | 62.152862 | 62.306080 | 62.152862 | 3 independent reference matches |

Connector `d83d504d65cd5b3bd14fd9bd559f5acad6ffedf2`; production JAR SHA256 `a9e069c287a027b84be4e1bbe03ef2f6025d8e843e563e49cbde7c3d6e4e70eb`. The plugin was built from a clean Git archive with Maven and Temurin 25. Trino 483, Redis Cloud 8.6, RESP3, verified 40 shards / 1000 GB all RAM, OSS Cluster API, no replication, noeviction, AOF every second, Standard QPF. Three r8g.16xlarge Redis hosts and an r7a.4xlarge runner share AWS us-east-1, a VPC, and physical AZ `use1-az6`; all three data disks were verified at 16000 IOPS / 1000 MiB/s. Trino restarts and runner page cache clears per query block while Redis stays running (`no-cold`). Each query has a 1200-second limit; best warm is the minimum of attempts 2 and 3.

Full-data Arrow ingestion plus indexing took **1036.644 seconds (17m 17s)**; exact SQL count and indexed document count both equal 99,997,497, with zero index failures. Source Parquet SHA256: `a390f6cb782f6aaef278c72fc1dd86c4f30bc843ebab3c159e9bd4d45ddb079f`. No 10M loader trials ran in this cohort.

Q24's captured first-attempt metrics report 15,911 candidate rows received, 10 exact hash commands, 1,050 hydrated fields, and 10 scan output rows. Q34's captured plan has partial and final Trino aggregation by URL, avoiding Redis GROUPBY's 1M-group limit. The column values, row ordering, and grouped counts match retained independent full-data DuckDB references. Original CSV checksums were verified and public artifacts scanned against private credentials.

This is a targeted acceptance cohort, not a new 43-query leaderboard result. The earlier result matrix below remains pinned to its original revision; these timings must not replace two rows in that matrix. A full 43-query sweep on one revision is needed to publish a complete new matrix.

Backup/restore speed testing is queued after the acceptance measurements. It has no measured speedup yet. The private S3 snapshot is configured for 30-day retention; compute teardown follows the diagnostic, with a verified fallback deadline of October 9 at 9:15 PM Pacific.

Original CSVs, samples, query plans, connector metrics, provenance, and independent correctness records are in `snapshot/out`.
