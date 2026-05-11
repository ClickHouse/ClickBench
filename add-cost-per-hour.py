#!/usr/bin/env python3
"""
Add `cost_per_hour` (USD) to the latest displayed result file per (system,
machine) for managed cloud services where list pricing is publicly available.

The field captures the published hourly list price for the exact hardware
configuration the benchmark was run on. Consumers can multiply it by
(load_time + sum of best query timings) to estimate the dollar cost of the
run.

Pricing sources are AWS us-east-1 unless otherwise noted; for clouds without
documented per-region rates, AWS list prices are reused as a published-list
approximation. Athena is intentionally omitted because its $5/TB-scanned
model has no hourly rate.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# --- ClickHouse Cloud (https://clickhouse.com/blog/how-cloud-data-warehouses-bill-you)
#     1 CU = 8 GiB / 2 vCPU.  AWS us-east-1 list rates:
#       Basic     $0.22 / CU-hr
#       Scale     $0.30 / CU-hr
#       Enterprise $0.39 / CU-hr
#     The benchmark uses Basic for 1-replica clusters and Scale for 2+.
#     Same rates are applied to GCP and Azure as a published-list approximation.
CH_BASIC = 0.22
CH_SCALE = 0.30


def clickhouse_cloud_cost(cluster_size, memory_gib):
    units = cluster_size * (memory_gib / 8)
    rate = CH_BASIC if cluster_size == 1 else CH_SCALE
    return round(units * rate, 4)


# Map (system_dir, basename) -> cost_per_hour in USD.
PRICING = {
    # --- AlloyDB (https://cloud.google.com/alloydb/pricing, us-central1)
    #     $0.06608 / vCPU-hr + $0.0112 / GB-hr (on-demand, list).
    #     64GiB ≈ 8 vCPU + 64 GB, 128GiB ≈ 16 vCPU + 128 GB.
    ("alloydb", "gcp.64GB.json"): round(8 * 0.06608 + 64 * 0.0112, 4),
    ("alloydb", "gcp.64GB_tuned.json"): round(8 * 0.06608 + 64 * 0.0112, 4),
    ("alloydb", "gcp.128GB_tuned.json"): round(16 * 0.06608 + 128 * 0.0112, 4),

    # --- Aurora Serverless v2 (https://aws.amazon.com/rds/aurora/pricing/)
    #     $0.12 / ACU-hr (Aurora Standard, us-east-1).  Both MySQL and Postgres.
    ("aurora-mysql", "16acu.json"): round(16 * 0.12, 4),
    ("aurora-postgresql", "16acu.json"): round(16 * 0.12, 4),

    # --- Crunchy Bridge for Analytics (https://www.crunchydata.com/pricing)
    #     Analytics-256 plan, memory-optimized tier, AWS eu-central-1.
    #     Warehouse-Memory-256 (32 vCPU, 256 GiB) lists at ~$5.74 / hr.
    ("crunchy-bridge-for-analytics", "crunchy-bridge-analytics-256.json"): 5.74,

    # --- Databricks SQL Serverless (https://www.databricks.com/product/pricing/databricks-sql)
    #     $0.70 / DBU in AWS US regions.  Warehouse DBU rates per size:
    #       2X-Small 4, X-Small 6, Small 12, Medium 24, Large 40,
    #       X-Large 80, 2X-Large 144, 3X-Large 272, 4X-Large 528.
    ("databricks", "2x-small.json"): round(4 * 0.70, 4),
    ("databricks", "x-small.json"): round(6 * 0.70, 4),
    ("databricks", "small.json"): round(12 * 0.70, 4),
    ("databricks", "medium.json"): round(24 * 0.70, 4),
    ("databricks", "large.json"): round(40 * 0.70, 4),
    ("databricks", "x-large.json"): round(80 * 0.70, 4),
    ("databricks", "2x-large.json"): round(144 * 0.70, 4),
    ("databricks", "4x-large.json"): round(528 * 0.70, 4),

    # --- Hologres (https://www.alibabacloud.com/help/en/hologres/product-overview/pay-as-you-go)
    #     Pay-as-you-go $0.182090 / CU-hr (Singapore).  16 CU per replica.
    ("hologres", "32core.json"): round(32 * 0.182090, 4),
    ("hologres", "64core.json"): round(64 * 0.182090, 4),
    ("hologres", "128core.json"): round(128 * 0.182090, 4),

    # --- MotherDuck (https://motherduck.com/product/pricing/)
    ("motherduck", "pulse.json"): 0.60,
    ("motherduck", "standard.json"): 2.40,
    ("motherduck", "jumbo.json"): 4.80,
    ("motherduck", "mega.json"): 12.00,

    # --- Redshift provisioned (https://aws.amazon.com/redshift/pricing/, us-east-1)
    #     dc2.8xlarge $4.80/node-hr, ra3.xlplus $1.086, ra3.4xlarge $3.26,
    #     ra3.16xlarge $13.04.
    ("redshift", "2x.dc2.8xlarge.json"): round(2 * 4.80, 4),
    ("redshift", "4x.ra3.xplus.json"): round(4 * 1.086, 4),
    ("redshift", "4x.ra3.4xlarge.json"): round(4 * 3.26, 4),
    ("redshift", "4x.ra3.16xlarge.json"): round(4 * 13.04, 4),

    # --- Redshift Serverless (https://aws.amazon.com/redshift/pricing/, us-east-1)
    #     The benchmark used "default configuration", which at launch was
    #     128 base RPUs at $0.375 / RPU-hr in us-east-1.
    ("redshift-serverless", "serverless.json"): round(128 * 0.375, 4),

    # --- SingleStore Helios (https://www.singlestore.com/cloud-pricing/, AWS US East 1)
    #     S-2 costs 2 credits/hr = $7.92/hr; credits at $3.96 list rate.
    ("singlestore", "s2.json"): 7.92,
    ("singlestore", "s24.json"): round(24 * 3.96, 4),
    # c6a.4xlarge run is self-hosted on EC2 (not a managed service); skip.

    # --- Snowflake (https://www.snowflake.com/en/pricing-options/, Standard, AWS us-east-1)
    #     $2.00 / credit.  Credits/hr by size: XS 1, S 2, M 4, L 8, XL 16,
    #     2XL 32, 3XL 64, 4XL 128.
    ("snowflake", "xs.json"): 2.00,
    ("snowflake", "s.json"): 4.00,
    ("snowflake", "m.json"): 8.00,
    ("snowflake", "l.json"): 16.00,
    ("snowflake", "xl.json"): 32.00,
    ("snowflake", "2xl.json"): 64.00,
    ("snowflake", "3xl.json"): 128.00,
    ("snowflake", "4xl.json"): 256.00,
    ("snowflake", "xs_interactive.json"): 2.00,

    # --- Timescale Cloud / Tiger Cloud (https://www.tigerdata.com/pricing, AWS)
    #     ~$560/mo (4 vCPU + 16 GiB) ≈ $0.767/hr; doubles per tier step.
    ("timescale-cloud", "4cpu.json"): 0.767,
    ("timescale-cloud", "8cpu.json"): 1.534,
    ("timescale-cloud", "16cpu.json"): 3.068,
}


def clickhouse_cloud_files():
    """Generate ClickHouse Cloud pricing entries from filenames like aws.3.16.json."""
    pattern = re.compile(r"^(aws|gcp|azure)\.(\d+)\.(\d+)\.json$")
    base = ROOT / "clickhouse-cloud" / "results"
    # Find the latest dated copy per basename, mirroring generate-results.sh.
    latest = {}
    for date_dir in sorted(p for p in base.iterdir() if p.is_dir()):
        for f in date_dir.iterdir():
            latest[f.name] = f
    for name, path in latest.items():
        m = pattern.match(name)
        if not m:
            continue
        cluster, mem = int(m.group(2)), int(m.group(3))
        yield path, clickhouse_cloud_cost(cluster, mem)


def latest_paths():
    """Yield (path, cost) for every file that should get cost_per_hour."""
    for (system, basename), cost in PRICING.items():
        sys_dir = ROOT / system / "results"
        if not sys_dir.is_dir():
            continue
        latest = None
        for date_dir in sorted(p for p in sys_dir.iterdir() if p.is_dir()):
            candidate = date_dir / basename
            if candidate.exists():
                latest = candidate
        if latest is None:
            print(f"warn: no file matched {system}/{basename}", file=sys.stderr)
            continue
        yield latest, cost
    yield from clickhouse_cloud_files()


def insert_cost(path: Path, cost: float) -> bool:
    text = path.read_text()
    if '"cost_per_hour"' in text:
        return False
    # Validate the file is parseable first.
    json.loads(text)
    # Insert immediately after the data_size line, copying its indentation.
    m = re.search(r'^(\s*)"data_size"\s*:[^\n]*\n', text, flags=re.MULTILINE)
    if not m:
        print(f"warn: no data_size line in {path}", file=sys.stderr)
        return False
    indent = m.group(1)
    insertion = f'{indent}"cost_per_hour": {cost},\n'
    new_text = text[: m.end()] + insertion + text[m.end():]
    json.loads(new_text)  # sanity check
    path.write_text(new_text)
    return True


def main():
    updated = 0
    skipped = 0
    for path, cost in latest_paths():
        if insert_cost(path, cost):
            updated += 1
            print(f"updated {path.relative_to(ROOT)} -> ${cost}/hr")
        else:
            skipped += 1
    print(f"\n{updated} updated, {skipped} skipped")


if __name__ == "__main__":
    main()
