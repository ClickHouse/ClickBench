#!/usr/bin/env python3
"""Generate the SynnoDB engine for the ClickBench queries. Not used by the benchmark itself: the
result is committed in engine/. See README.md.

It follows SynnoDB's own tutorials/gen_clickbench_demo.ipynb: register the workload from a DuckDB
database that holds `hits`, then `createStoragePlan` and `createBaseImpl` with in-memory storage.
The difference is the workload: the notebook uses ten parameterized rewrites of ClickBench
queries, this uses the queries of queries.sql as they are.

The factory needs `pip install "synnodb[factory]"`, the system libraries of SynnoDB's README, and
a model, given through the environment exactly as SynnoDB documents:

    ANTHROPIC_API_KEY=...                with --model anthropic/claude-sonnet-5
    LLM_API_BASE=http://host:port/v1     with --model openai/<served-model>

Example:

    ./generate.py --db hits.duckdb --threads 16 --data-root synno_data \\
        --exclude 18,24,25,27,43

The engine is published under <data-root>/engines/<engine id>/. Copy that directory to engine/
without `db` and `build/`.
"""
import argparse
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument("--db", required=True, help="DuckDB database with the hits table of create.sql")
ap.add_argument("--queries", default=str(HERE / "queries.sql"), help="one query per line")
ap.add_argument("--exclude", default="", help="comma-separated query numbers (from 1) to leave to DuckDB")
ap.add_argument("--only", default="", help="comma-separated query numbers (from 1) to generate; default: all")
ap.add_argument("--name", default="clickbench", help="the name of the workload in SynnoDB")
ap.add_argument("--model", default=os.environ.get("SYNNO_MODEL", "anthropic/claude-sonnet-5"))
ap.add_argument("--threads", type=int, required=True, help="threads the engine is generated, validated and served with")
ap.add_argument("--max-turns", type=int, default=450, help="LLM turns per stage, as in SynnoDB's notebook")
ap.add_argument("--data-root", required=True, help="SynnoDB's data directory (workloads, caches, engines)")
ap.add_argument("--plan-file", default="storage_plan.txt", help="where the storage plan is saved, and read back from")
ap.add_argument("--stages", default="plan,base", help="plan: createStoragePlan; base: createBaseImpl")
args = ap.parse_args()

# The factory starts a dashboard that serves the generated sources and binds it to all
# interfaces. Keep it on the loopback.
from synnodb.observability.live_ui import live_dashboard

live_dashboard.LiveDashboardDrain.__init__.__defaults__ = ("127.0.0.1", 8765)

from synnodb import SynnoDB

exclude = {int(x) for x in args.exclude.split(",") if x}
only = {int(x) for x in args.only.split(",") if x}
lines = [line.strip() for line in open(args.queries) if line.strip()]
# The identifier of a query in SynnoDB is its number in queries.sql.
queries = {
    str(number): {"sql": sql}
    for number, sql in enumerate(lines, 1)
    if number not in exclude and (not only or number in only)
}
print(f"Registering {len(queries)} of {len(lines)} queries: {', '.join(queries)}", flush=True)

db = SynnoDB(
    model=args.model,
    db_storage="in_memory",
    data_dir=Path(args.data_root).resolve(),
    threads=args.threads,
    max_turns=args.max_turns,
)
spec = db.sync_from_duckdb(
    str(Path(args.db).resolve()),
    name=args.name,
    queries_json=queries,
    schema_example_table="hits",
)
print("Workload:", spec.name, "| tables:", spec.tables, "| queries:", spec.all_query_ids, flush=True)
print("Subsets :", spec.exhaustive_sfs, "(benchmark:", spec.benchmark_sf, ")", flush=True)

stages = args.stages.split(",")
plan_file = Path(args.plan_file)
if "plan" in stages:
    plan = db.createStoragePlan()
    plan_file.write_text(plan.text)
    print("Storage plan written to", plan_file, "| snapshot:", plan.snapshot_hash, flush=True)

if "base" in stages:
    impl = db.createBaseImpl(storage_plan=plan_file.read_text())
    print("Base implementation:", impl.workspace, "| snapshot:", impl.snapshot_hash, flush=True)
    print("Engines published under:", Path(args.data_root).resolve() / "engines", flush=True)
