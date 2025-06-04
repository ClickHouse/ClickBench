> TiDB is an open-source, cloud-native, distributed SQL database designed for high availability, horizontal and vertical scalability, strong consistency, and high performance.

— [TiDB GitHub repository](https://github.com/pingcap/tidb)

> TiKV is an open-source, distributed, and transactional key-value database.

— [TiKV GitHub repository](https://github.com/tikv/tikv)

> TiFlash is a columnar storage component of TiDB. It mainly plays the role of Analytical Processing (AP) in the Hybrid Transactional/Analytical Processing (HTAP) architecture of TiDB.

— [TiFlash GitHub repository](https://github.com/pingcap/tiflash)

**Notes:**

- Data import is done with [TiDB Lightning](https://docs.pingcap.com/tidb/stable/tidb-lightning-overview/).
- Evaluation is done in a similar way as in [PingCAP's VLDB 2020 Paper](https://www.vldb.org/pvldb/vol13/p3072-huang.pdf).
    - TiKV only: `benchmark.sh tikv`
    - TiFlash only: `benchmark.sh tiflash`
- Detected anomalies and errors:
  - TiKV only: Q33 and Q34 exceeded the default `tidb_mem_quota_query` of 1GB. When increasing the quota to positive infinity (`SET tidb_mem_quota_query = 0;`), queries either get stuck or terminate with `ERROR 9001 (HY000): PD server timeout:`.
  - TiFlash only:
    - During the benchmark, Q19, Q20, Q34 and Q35 failed with an error similar to the one listed below. When running the queries manually after the benchmark, Q19, Q34 and Q35 again failed, but Q20 _completed_ in 0.10 seconds.
      ```
      ERROR 1105 (HY000) at line 1: other error for mpp stream: Code: 0, e.displayText() = DB::Exception:
      Memory limit (total) exceeded caused by 'RSS(Resident Set Size) much larger than limit' :
      process memory size would be 25.54 GiB for (attempt to allocate chunk of 1049104 bytes),
      limit of memory for data computing : 24.52 GiB. Memory Usage of Storage: non-query: peak=1.84 GiB,
      amount=1.04 GiB; kvstore: peak=120.61 MiB, amount=0.00 B; query-storage-task: peak=1.03 GiB, amount=1.62 MiB;
      fetch-pages: peak=0.00 B, amount=0.00 B; shared-colum
      ```
- For benchmarks that may read from TiFlash, HTAP capabilities (i.e., TiFlash replicas) are activated _before_ any data is inserted.
