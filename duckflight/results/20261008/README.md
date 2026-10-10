# DuckFlight v0.1.12 on c6a.4xlarge

Measured on October 8, 2026 (UTC) with the standard 99,997,497-row dataset,
unchanged DuckDB schema and all 43 queries. The run used ClickBench revision
`e90045879276f75cc398f1ab8a73541a7716058d` and its shared runner, including the
ten-client, 600-second concurrency phase.

| Measurement | Result |
|---|---:|
| Load time | 133.323 s |
| Data size, including WAL | 20,460,975,726 bytes |
| Sum of 43 cold-query times | 118.401108183 s |
| Sum of 43 warm minima (attempts 2–3) | 21.173516373 s |
| Supplementary concurrent throughput | 1.435 queries/s |
| Concurrent error ratio | 0 |

All 129 timed executions completed successfully. The sums above describe this
run; they are not the website's geometric-mean relative score.

The dedicated AWS `c6a.4xlarge` instance used 16 vCPUs (AMD EPYC 7R13), 32 GiB
memory, Ubuntu 24.04, and a fresh encrypted 500 GiB gp2 root disk. No swap,
workload-specific tuning, or result cache was enabled. DuckDB used its default
thread and memory settings. The database used `storage_version 'latest'`.

The official DuckDB CLI 1.5.6 hosted the published DuckFlight v0.1.12 extension.
Clients used Python 3.12, ADBC Flight SQL/manager 1.12.0, and PyArrow 25.0.1 with
`uv.lock`. Authentication happened before each timer. Timings include direct
execution, complete result transfer, and conversion to Python rows; they exclude
client startup, authentication, CSV formatting, and teardown. Every cold attempt
stopped the complete host before clearing the OS page cache. See the main README
for the complete measurement contract and reproduction commands.

The supplementary concurrent throughput includes client-process startup,
authentication, and output formatting, so it measures the provided hook's
throughput rather than persistent-client saturation.

After the benchmark, `baseline.py` compared all 43 complete result multisets
against direct DuckDB on the same database. Thirty-five matched directly; eight
nonunique LIMIT boundaries matched after adding deterministic ORDER BY tie
breakers for validation only. The timed SQL was unchanged. Floating aggregates
used relative tolerance 1e-10 and absolute tolerance 1e-9. No differences remained.

Provenance:

- [Published extension v0.1.12](https://github.com/sidequery/duckflight-extension/releases/tag/v0.1.12).
- Extension source `d6646edb7877ab65f39ffa1cfe53b5d090f3694b`; harness source
  `d81458843995f5c6d23e21ea3c6aca8d29e70c83`.
- Linux amd64 extension SHA-256:
  `c274636b29671a5453c12d169003da8dc21c0b01f64f62074406acdfdc9f3eaf`.
- `harness.py` SHA-256:
  `35a40512a088e5a9a77cf86b5d79b9ee3a1c37bdb5f10a4dd395e5f5a1f8fae1`.
- `uv.lock` SHA-256:
  `4f7443f805fdb6057af2459fdedfa61e6ab2f0f9b097a4b86b07e2429da2dac6`.
