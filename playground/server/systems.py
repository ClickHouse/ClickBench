"""Registry of ClickBench systems that can be exposed through the playground.

A system is *playground-eligible* if its directory contains the canonical
unified script set (install/start/load/query/check/stop) AND there is no
external service required (no `aurora-*`, `redshift*`, `bigquery`, `snowflake`,
etc. — those need API keys and live on someone else's infra).

The registry is built by scanning the repo at startup. Each `System` carries:

  * name              the directory name (also the URL-safe identifier)
  * display_name      pulled from template.json "system" field if present
  * tags              from template.json
  * download_script   from `BENCH_DOWNLOAD_SCRIPT=` line in benchmark.sh
  * data_format       inferred from download_script (parquet / parquet-partitioned / tsv / csv / none)
  * durable           BENCH_DURABLE=yes/no (default yes)
  * restartable       BENCH_RESTARTABLE=yes/no (default yes)
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# Systems we explicitly skip — they all require external infrastructure
# (managed cloud DBs / API keys) we can't run inside an isolated microVM.
# Local-only systems (umbra, hyper, cedardb, etc.) stay in the catalog
# even though some need a free-trial license at install time — those
# scripts fetch the binary themselves and we don't second-guess them.
_EXTERNAL = {
    # Managed cloud services / require API keys / external infra.
    "alloydb", "athena", "athena-partitioned", "aurora-mysql",
    "aurora-postgresql", "bigquery", "brytlytdb", "bytehouse", "chyt",
    "clickhouse-cloud", "clickhouse-tencent",
    "crunchy-bridge-for-analytics", "databricks", "exasol",
    "gravitons", "hologres", "hydrolix",
    "motherduck", "pgpro_tam", "redshift", "redshift-serverless",
    "s3select", "singlestore", "snowflake", "supabase",
    "tembo-olap", "timescale-cloud", "tinybird", "velodb",
    "vertica", "ydb",
    # duckdb-memory runs duckdb with the database in :memory:. Even with
    # a generous swap drive, the 100M-row hits set blows past anything
    # reasonable here; duckdb has an on-disk fallback that we use via
    # the regular `duckdb` entry, so disable the memory variant.
    "duckdb-memory",
    # sirius is a GPU-accelerated DuckDB extension that links against
    # CUDA at runtime. Our microVMs have no GPU; install compiles fine
    # (~35 min from source) but ./check times out because the daemon
    # can't initialize a CUDA context. Disabled — we'd need GPU passthrough.
    "sirius",
    # oxla's only public docker image, public.ecr.aws/oxla/release,
    # was de-listed (the ECR public gallery no longer surfaces the
    # repository at all). No replacement on Docker Hub or GitHub
    # Releases. Drop until upstream publishes a new image source.
    "oxla",
    # Upstream is broken, asks for credentials we don't have, or
    # the engine can't survive a 16 GB cap.
    # - paradedb-partitioned: install script aborts ("pg_lakehouse was
    #   removed from ParadeDB after 0.10.x"); historical benchmark only.
    # - paradedb: postgres backend crashes during index VACUUM under
    #   16 GB RAM; not investigable without bumping VM RAM.
    # - pg_duckdb-motherduck: requires MOTHERDUCK_TOKEN (cloud creds).
    "paradedb", "paradedb-partitioned", "pg_duckdb-motherduck",
    # kdb (KDB-X Community Edition): the CE license does not allow
    # serving KDB-X to third parties (the same reason kdb is listed
    # under "results cannot be published" in the top-level README).
    # The kdb/ scripts stay so an operator can reproduce results
    # locally, but the playground never exposes it.
    "kdb",
}

# Systems that need outbound access at query time get routed through
# the SNI-allowlist proxy on the host (see sni_proxy.py +
# net.enable_filtered_internet). Only HTTPS to the S3 hosts in
# sni_proxy.DEFAULT_ALLOW survives; everything else is dropped. The
# ClickHouse-family engines used to live in a separate
# `TRUSTED_INTERNET` set that gave them unrestricted egress (so an
# arbitrary user SQL could `url('http://169.254.169.254/...')` or
# reach internal hosts) — that set is gone; they all now use this
# filtered path too.
DATALAKE_FILTERED: frozenset[str] = frozenset({
    "chdb",
    "chdb-parquet",
    "chdb-parquet-partitioned",
    "clickhouse",
    "clickhouse-datalake",
    "clickhouse-datalake-partitioned",
    "clickhouse-parquet",
    "clickhouse-parquet-partitioned",
    # clickhouse-web ATTACHes the table to a remote web disk pointed at
    # https://clickhouse-public-datasets.s3.amazonaws.com/web/ — every
    # query pulls parts on demand, so it needs post-snapshot S3 access.
    "clickhouse-web",
    "duckdb-datalake",
    "duckdb-datalake-partitioned",
    "presto-datalake",
    "presto-datalake-partitioned",
    "trino-datalake",
    "trino-datalake-partitioned",
})

# DataFrame / in-process engines load the full 100M-row hits set into a
# single in-process structure. Observed working set can reach 250 GB,
# well past the playground's 16 GB VM RAM cap. Give each of these a
# dedicated raw swap block device (mkswap + swapon at agent startup);
# the swap disk is reflink-snapshotted alongside rootfs/sysdisk so a
# restored VM resumes with the same swap pages it had at snapshot time.
NEEDS_SWAP: frozenset[str] = frozenset({
    "chdb-dataframe",
    "duckdb-dataframe",
    "polars-dataframe",
    "daft-parquet",
    "daft-parquet-partitioned",
    "pandas",
    # Umbra OOMs during load on the 16 GB cap (`psql:create.sql:109:
    # ERROR: unable to allocate memory` after ~70M rows of COPY).
    # The docker container has no memory.swap.max set, so the guest
    # kernel will swap it the same as any process.
    "umbra",
})

# Sparse size of the swap.raw block device handed to NEEDS_SWAP systems.
# 256 GiB matches the upper bound we've seen these engines hit on the
# partitioned-parquet set.
SWAP_SIZE_GB: int = 256

# Per-system sysdisk-size override (apparent size, in GiB). Default is
# 200 GiB as set by build-system-rootfs.sh. The image is sparse so the
# apparent size doesn't cost physical bytes upfront — only what the
# guest actually writes. Rootfs is intentionally not overridable here:
# the build script clones the base ext4 image via sparse-cp without
# resize2fs, so a bigger rootfs would require a deeper change.
SYSDISK_OVERRIDES_GB: dict[str, int] = {
    # postgresql-orioledb's COPY blew through 200 GiB before reaching
    # the end of hits.tsv:
    #   PANIC: could not write buffer to file orioledb_undo/0000000319page:
    #          No space left on device  (line 69,533,798 of hits.tsv)
    # The orioledb extension keeps a per-statement undo log inside
    # PGDATA that roughly doubles the write footprint of the base
    # table. The install script parks PGDATA on the sysdisk
    # specifically so this override actually helps.
    "postgresql-orioledb": 400,
}


@dataclass(frozen=True)
class System:
    name: str
    display_name: str
    tags: tuple[str, ...]
    download_script: str
    data_format: str  # parquet / parquet-partitioned / tsv / csv / none
    durable: bool
    restartable: bool

    def asdict(self) -> dict:
        return {
            "name": self.name,
            "display_name": self.display_name,
            "tags": list(self.tags),
            "download_script": self.download_script,
            "data_format": self.data_format,
            "durable": self.durable,
            "restartable": self.restartable,
        }


def _read_template(p: Path) -> dict:
    tpl = p / "template.json"
    if not tpl.exists():
        return {}
    try:
        return json.loads(tpl.read_text())
    except Exception:
        return {}


def _parse_benchmark_sh(p: Path) -> dict:
    """Best-effort parse of `export FOO=bar` lines in benchmark.sh."""
    bench = p / "benchmark.sh"
    if not bench.exists():
        return {}
    out: dict[str, str] = {}
    pat = re.compile(r'^\s*export\s+([A-Z_]+)=("([^"]*)"|([^\s]+))', re.MULTILINE)
    text = bench.read_text(errors="replace")
    for m in pat.finditer(text):
        key = m.group(1)
        out[key] = m.group(3) if m.group(3) is not None else m.group(4)
    return out


def _data_format(download_script: str) -> str:
    if not download_script:
        return "none"
    if "parquet-partitioned" in download_script:
        return "parquet-partitioned"
    if "parquet-single" in download_script:
        return "parquet"
    if "tsv" in download_script:
        return "tsv"
    if "csv" in download_script:
        return "csv"
    return "unknown"


def _is_playground_eligible(p: Path) -> bool:
    if p.name in _EXTERNAL:
        return False
    for f in ("install", "start", "load", "query", "check", "stop"):
        s = p / f
        if not s.exists():
            return False
    return True


def discover(repo_dir: Path) -> dict[str, System]:
    """Walk the repo and return name -> System."""
    out: dict[str, System] = {}
    for child in sorted(repo_dir.iterdir()):
        if not child.is_dir():
            continue
        if not _is_playground_eligible(child):
            continue
        tpl = _read_template(child)
        env = _parse_benchmark_sh(child)
        download = env.get("BENCH_DOWNLOAD_SCRIPT", "")
        out[child.name] = System(
            name=child.name,
            display_name=tpl.get("system", child.name),
            tags=tuple(tpl.get("tags", []) or []),
            download_script=download,
            data_format=_data_format(download),
            durable=env.get("BENCH_DURABLE", "yes") != "no",
            restartable=env.get("BENCH_RESTARTABLE", "yes") != "no",
        )
    return out
