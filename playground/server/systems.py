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
    "clickhouse-cloud", "clickhouse-tencent", "clickhouse-web",
    "crunchy-bridge-for-analytics", "databend", "databricks", "exasol",
    "firebolt", "firebolt-parquet", "firebolt-parquet-partitioned",
    "gravitons", "heavyai", "hologres", "hydrolix", "kinetica",
    "motherduck", "oxla", "pgpro_tam", "redshift", "redshift-serverless",
    "s3select", "singlestore", "snowflake", "supabase",
    "tembo-olap", "timescale-cloud", "tinybird", "velodb",
    "vertica", "ydb",
    # DataFrame-style: load the full hits dataset into a single in-process
    # DataFrame and run queries from RAM. Observed peak RSS for chdb-
    # dataframe / duckdb-dataframe is ~80-100 GB on the partitioned
    # parquet set; sustaining that for 98 concurrent VMs is infeasible
    # even though KVM allocates lazily, so they don't fit the playground's
    # model. Disabled — not "broken", just over-provisioned for shared use.
    "chdb-dataframe", "duckdb-dataframe", "polars-dataframe",
    "daft-parquet", "daft-parquet-partitioned",
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
