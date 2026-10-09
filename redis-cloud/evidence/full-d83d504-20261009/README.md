## Complete PR154 driver sweep: October 9, 2026 Pacific

All **43 unchanged queries, three attempts each (129 outputs), pass independent full-data validation** on 99,997,497 rows. This is one consistent connector revision, `d83d504d65cd5b3bd14fd9bd559f5acad6ffedf2`, with production JAR SHA256 `a9e069c287a027b84be4e1bbe03ef2f6025d8e843e563e49cbde7c3d6e4e70eb`. No targeted acceptance samples or older-revision timings are substituted. Q24 best warm is **2.991580s** and Q34 **62.044117s**; both previous failure cases pass all three attempts.

Trino 483, Redis Cloud 8.6, RESP3, OSS Cluster API, verified 40 shards / 1000 GB all RAM, Standard QPF, no replication, noeviction, AOF every second. Three AWS r8g.16xlarge Redis hosts plus an r7a.4xlarge Trino runner share us-east-1, VPC and physical AZ use1-az6. Data disks have 16000 IOPS / 1000 MiB/s. Trino restarts and runner page cache clears per query block; Redis stays running, so `no-cold` applies. Query limit: 1200 seconds. Best warm is the minimum of attempts 2 and 3. Persistent data size is unmeasured. No verified default-versus-OSS server comparison is available.

### Backup initialization and ingestion

This sweep used the verified compatible full-data backup. Restore plus verified index readiness took **545.174150s (9m 5s)**, versus **1036.643924s (17m 17s)** for separately measured fresh Arrow ingestion plus indexing on the same driver: **1.9015x** faster in this single-trial setup diagnostic. Restore time is not ingestion and is not reported as ClickBench `load_time`; that field retains the separately measured fresh-ingestion value, excluding download and table creation. The premature 16.445s readiness observation saw old data before asynchronous import started and is invalid and excluded.

All 40 RDB files (50,181,080,429 bytes) have verified SHA256 values. Exact restored SQL/index counts are 99,997,497, with zero index failures; post-restore Q24/Q34/Q35 outputs independently validate. The private encrypted S3 backup has 30-day object expiry and is retained after compute teardown. Raw RDB files and credentials are not published.

For future benchmark initialization, **always restore a verified compatible backup when available**. Verify every shard checksum, dataset/source/schema and Redis compatibility, exact restored SQL/index counts, zero index failures and independent query correctness. Use fresh ingestion when no suitable backup exists or when explicitly measuring ingestion performance. Keep restore setup timing separate from ingestion metrics.

| Query | Attempt 1 (s) | Attempt 2 (s) | Attempt 3 (s) | Best warm (s) | Correctness |
|---|---:|---:|---:|---:|---|
| Q1 | 2.949415 | 2.838876 | 2.839760 | 2.838876 | 3 valid outputs |
| Q2 | 0.281510 | 0.192954 | 0.185813 | 0.185813 | 3 valid outputs |
| Q3 | 6.524263 | 6.428483 | 6.478129 | 6.428483 | 3 valid outputs |
| Q4 | 4.086578 | 3.991875 | 4.009102 | 3.991875 | 3 valid outputs |
| Q5 | 106.994954 | 101.596537 | 99.663822 | 99.663822 | 3 valid outputs |
| Q6 | 71.255473 | 63.358781 | 63.014049 | 63.014049 | 3 valid outputs |
| Q7 | 67.309233 | 62.859659 | 57.794620 | 57.794620 | 3 valid outputs |
| Q8 | 2.671320 | 1.901141 | 1.954668 | 1.901141 | 3 valid outputs |
| Q9 | 108.169553 | 104.407130 | 105.166889 | 104.407130 | 3 valid outputs |
| Q10 | 111.883567 | 100.865239 | 101.657988 | 100.865239 | 3 valid outputs |
| Q11 | 116.309333 | 101.769272 | 101.259427 | 101.259427 | 3 valid outputs |
| Q12 | 110.231814 | 103.101666 | 103.428366 | 103.101666 | 3 valid outputs |
| Q13 | 71.384488 | 58.733820 | 63.422950 | 58.733820 | 3 valid outputs |
| Q14 | 109.603335 | 102.026118 | 100.548743 | 100.548743 | 3 valid outputs |
| Q15 | 83.157092 | 67.814141 | 72.072635 | 67.814141 | 3 valid outputs |
| Q16 | 107.357466 | 101.758360 | 99.840934 | 99.840934 | 3 valid outputs |
| Q17 | 108.229105 | 99.352973 | 101.241822 | 99.352973 | 3 valid outputs |
| Q18 | 108.746655 | 103.092399 | 99.390767 | 99.390767 | 3 valid outputs |
| Q19 | 112.548316 | 100.350021 | 104.333626 | 100.350021 | 3 valid outputs |
| Q20 | 0.238739 | 0.112976 | 0.105313 | 0.105313 | 3 valid outputs |
| Q21 | 4.549125 | 4.457410 | 4.460852 | 4.457410 | 3 valid outputs |
| Q22 | 14.653248 | 7.637822 | 7.606456 | 7.606456 | 3 valid outputs |
| Q23 | 14.883391 | 7.686048 | 7.678627 | 7.678627 | 3 valid outputs |
| Q24 | 3.168479 | 2.991580 | 3.005566 | 2.991580 | 3 valid outputs |
| Q25 | 88.264063 | 69.896392 | 69.610698 | 69.610698 | 3 valid outputs |
| Q26 | 67.273928 | 57.264276 | 57.938492 | 57.264276 | 3 valid outputs |
| Q27 | 80.668309 | 74.201337 | 69.456862 | 69.456862 | 3 valid outputs |
| Q28 | 90.173839 | 74.217984 | 71.970268 | 71.970268 | 3 valid outputs |
| Q29 | 73.233046 | 63.860541 | 63.317530 | 63.317530 | 3 valid outputs |
| Q30 | 66.578750 | 57.968464 | 59.927839 | 57.968464 | 3 valid outputs |
| Q31 | 112.252675 | 99.735685 | 102.151100 | 99.735685 | 3 valid outputs |
| Q32 | 116.807249 | 111.847437 | 111.193444 | 111.193444 | 3 valid outputs |
| Q33 | 113.791374 | 101.690890 | 108.469994 | 101.690890 | 3 valid outputs |
| Q34 | 73.787982 | 62.044117 | 62.563425 | 62.044117 | 3 valid outputs |
| Q35 | 73.478535 | 63.798067 | 62.253618 | 62.253618 | 3 valid outputs |
| Q36 | 70.841405 | 59.693944 | 60.705792 | 59.693944 | 3 valid outputs |
| Q37 | 2.994225 | 2.565837 | 2.373994 | 2.373994 | 3 valid outputs |
| Q38 | 2.982137 | 2.319347 | 2.202879 | 2.202879 | 3 valid outputs |
| Q39 | 0.906873 | 0.575224 | 0.551283 | 0.551283 | 3 valid outputs |
| Q40 | 4.813524 | 3.895219 | 3.910068 | 3.895219 | 3 valid outputs |
| Q41 | 1.569389 | 1.137893 | 1.026270 | 1.026270 | 3 valid outputs |
| Q42 | 1.318841 | 0.961890 | 0.912079 | 0.912079 | 3 valid outputs |
| Q43 | 2.896885 | 2.226068 | 2.197874 | 2.197874 | 3 valid outputs |

Original CSVs, SQL, plans, metrics, provenance and correctness records are in `snapshot/out`. Archive and CSV checksums were verified.
