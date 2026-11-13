#!/usr/bin/env python3
"""The reference: the generated dataset in a ClickHouse MergeTree table, and the
results of the queries on it, computed with the pinned ClickHouse.

  reference.py load <work dir> <db dir>
      Loads <work dir>/canonical/part_*.parquet into the table hits in <db dir>.
  reference.py run <db dir> <queries.json> <output dir> [--timeout S]
      Runs every query; writes <output dir>/<id>.tsv with the result in TSVWithNames
      and <output dir>/status.json with {id: {status, time, error}}.

The settings in reference-settings make ClickHouse follow the SQL standard
(NULLs from outer joins, NULL from SUM over no rows, DISTINCT by default for
UNION/INTERSECT/EXCEPT); these are the semantics the queries are written for.
For the same reason, LENGTH, SUBSTRING, LOWER and UPPER are rewritten to their
UTF-8 variants, which work on characters (lib/sqlrewrite.py).
"""

import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CLICKBENCH = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import sqlrewrite  # noqa: E402
CLICKHOUSE = os.environ.get("RANDOM_CLICKHOUSE", "/opt/random/clickhouse")


def reference_settings():
    settings = []
    with open(os.path.join(HERE, "reference-settings")) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                settings.append("--" + line)
    return settings


def create_table_sql():
    """clickhouse/create.sql without the settings that only matter there."""
    with open(os.path.join(CLICKBENCH, "clickhouse", "create.sql")) as f:
        sql = f.read()
    sql = sql.replace("CREATE OR REPLACE TABLE", "CREATE TABLE")
    return sql[:sql.index("ENGINE")] + "ENGINE = MergeTree"


def clickhouse_local(db, query, settings=(), timeout=None, output_format="TSV"):
    args = [CLICKHOUSE, "local", "--path", db, "--format", output_format,
            *reference_settings(), *settings, "--query", query]
    env = dict(os.environ, TZ="UTC")
    # Not in the current directory: clickhouse-local reads config.xml from it.
    return subprocess.run(args, capture_output=True, timeout=timeout, env=env, cwd=os.path.dirname(db))


def load(work, db):
    os.makedirs(db, exist_ok=True)
    with open(os.path.join(work, "structure.txt")) as f:
        structure = f.read().strip()
    start = time.time()
    for query in ["DROP TABLE IF EXISTS hits", create_table_sql(),
                  f"INSERT INTO hits SELECT * FROM file('{work}/canonical/part_*.parquet', Parquet, $${structure}$$)",
                  "OPTIMIZE TABLE hits FINAL"]:
        result = clickhouse_local(db, query)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode(errors="replace"))
    print(f"Loaded the reference in {time.time() - start:.1f} s", file=sys.stderr)


def run_query(db, sql, settings=(), timeout=600, output_format="TSVWithNames"):
    """Returns (status, seconds, output bytes, error text). The string functions
    of the query are rewritten to their character-wise variants (see
    sqlrewrite.py), for the standard semantics."""
    sql = sqlrewrite.clickhouse_standard(sql)
    start = time.time()
    try:
        result = clickhouse_local(db, sql, settings=[f"--max_execution_time={timeout}", *settings], output_format=output_format,
                                  timeout=timeout + 60)
    except subprocess.TimeoutExpired:
        return "timeout", time.time() - start, b"", "timeout"
    elapsed = time.time() - start
    if result.returncode != 0:
        error = result.stderr.decode(errors="replace").strip()
        status = "timeout" if "TIMEOUT_EXCEEDED" in error else "error"
        return status, elapsed, b"", error[-2000:]
    return "ok", elapsed, result.stdout, ""


def run(db, queries_file, out, timeout=600):
    os.makedirs(out, exist_ok=True)
    with open(queries_file) as f:
        queries = json.load(f)["queries"]
    status = {}
    for q in queries:
        s, elapsed, output, error = run_query(db, q["sql"], timeout=timeout)
        if s == "ok":
            with open(os.path.join(out, q["id"] + ".tsv"), "wb") as f:
                f.write(output)
        status[q["id"]] = {"status": s, "time": round(elapsed, 3), "error": error}
        print(f"reference {q['id']}: {s} {elapsed:.3f} s", file=sys.stderr)
    with open(os.path.join(out, "status.json"), "w") as f:
        json.dump(status, f, indent=1)


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "load":
        load(os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3]))
    elif len(sys.argv) >= 5 and sys.argv[1] == "run":
        timeout = 600
        if "--timeout" in sys.argv:
            timeout = int(sys.argv[sys.argv.index("--timeout") + 1])
        run(os.path.abspath(sys.argv[2]), sys.argv[3], sys.argv[4], timeout)
    else:
        sys.exit(__doc__)
