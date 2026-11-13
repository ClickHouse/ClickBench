#!/usr/bin/env python3
"""Translates the generated queries into the dialect or the query language of a
system, with a language model.

Usage: translate-queries.py <queries.json> <system> <output.json>

The model learns the dialect from the system's own ClickBench entry: its 43
queries side by side with the same queries for ClickHouse, the files that
create its tables (for the table name and the types, e.g. the integer times of
the Parquet files), and the notes in random/systems/<system>/notes.md if there
are any. The generated queries are written in portable SQL with the semantics
of ClickHouse under the reference settings, and the translation must keep the
result exactly: the same columns in the same order, the same rows in the same
order.

A system whose queries.sql is the same as ClickHouse's gets the queries
unchanged, unless random/systems/<system>/config says TRANSLATE=yes (and a
system can opt out with TRANSLATE=no). A query that the target can't express
is marked as unsupported and counts as an error of the system.

random/systems/<system>/config can also give QUERY_SUFFIX, appended to every
query: ClickHouse uses it for the settings of the standard semantics, and
REWRITE=clickhouse-standard for the character-wise string functions.
"""

import concurrent.futures
import glob
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import llm  # noqa: E402

CLICKBENCH = os.path.dirname(HERE)
BATCH = 20

SYSTEM_PROMPT = """You translate SQL queries between database systems for a benchmark. Correctness
matters more than anything: the results of the translated queries are compared with
the results of the original queries, value by value and row by row."""


def read(path, limit=30000):
    with open(path, errors="replace") as f:
        return f.read()[:limit]


def system_config(system):
    config = {}
    path = os.path.join(HERE, "systems", system, "config")
    if os.path.exists(path):
        for line in read(path).splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
    return config


def needs_translation(system):
    setting = system_config(system).get("TRANSLATE", "")
    if setting in ("yes", "no"):
        return setting == "yes"
    return read(os.path.join(CLICKBENCH, system, "queries.sql")) != read(
        os.path.join(CLICKBENCH, "clickhouse", "queries.sql"))


def context(system):
    clickhouse = read(os.path.join(CLICKBENCH, "clickhouse", "queries.sql")).splitlines()
    target = read(os.path.join(CLICKBENCH, system, "queries.sql")).splitlines()
    pairs = "\n\n".join(f"ClickHouse: {a}\n{system}: {b}" for a, b in zip(clickhouse, target))
    files = ""
    for path in sorted(glob.glob(os.path.join(CLICKBENCH, system, "create*"))):
        files += f"\n--- {os.path.basename(path)} ---\n{read(path)}\n"
    notes_path = os.path.join(HERE, "systems", system, "notes.md")
    notes = read(notes_path) if os.path.exists(notes_path) else ""
    # The documentation of the language, for the systems that list it.
    docs_path = os.path.join(HERE, "systems", system, "docs")
    if os.path.exists(docs_path):
        for url in read(docs_path).split():
            if url.startswith("http"):
                with urllib.request.urlopen(url, timeout=60) as response:
                    notes += f"\n--- documentation: {url} ---\n" + response.read(80000).decode(errors="replace")
    return pairs, files, notes


def prompt(system, batch, pairs, files, notes):
    queries = "\n".join(json.dumps({"id": q["id"], "sql": q["sql"]}, ensure_ascii=False) for q in batch)
    return f"""Translate queries for the system "{system}".

The source queries run in ClickHouse with these settings, which give the standard SQL
semantics: join_use_nulls=1 (outer joins produce NULLs), aggregate_functions_null_for_empty=1
(SUM/AVG/MIN/MAX over no rows give NULL), group_by_use_nulls=1, UNION/INTERSECT/EXCEPT
mean DISTINCT unless ALL is written, `/` is floating-point division, timezone UTC.
The table `hits` has the columns of the ClickBench dataset; in ClickHouse EventTime,
ClientEventTime and LocalEventTime are DateTime and EventDate is Date.

How the queries of the standard ClickBench benchmark look in ClickHouse and in {system}
(the same queries, line by line):

{pairs}

The files that create the tables in {system}:
{files}
{"Notes about " + system + ":" + chr(10) + notes if notes else ""}

Rules:
- Keep the result exactly: the same output columns in the same order, the same rows in
  the same order, the same values (in particular, keep the types of times and dates
  as times and dates, as the examples show).
- Use the table names, types, conversions and functions of {system} as the examples
  and the files above show.
- Every translation is one statement or expression in the query language of {system},
  in the form its queries file uses (one line, as in the examples).
- Use any feature of {system} (see the documentation if given), not only the ones the
  examples show; rewrite the query into another shape when needed (a CTE into a
  derived table, a correlated subquery into a join with an aggregate), as long as
  the result stays the same.
- If {system} cannot express a query with the same result, give null for it.

The queries, one JSON object per line:
{queries}

Answer with a JSON object that maps every id to its translation (a string) or null,
and nothing else.
"""


def extract_json(text):
    match = re.search(r"```(?:json)?\s*(\{.*\})\s*```", text, re.S)
    if match:
        return json.loads(match.group(1))
    return json.loads(text[text.find("{"):text.rfind("}") + 1])


def translate(queries, system):
    if not needs_translation(system):
        return {q["id"]: q["sql"] for q in queries}, "none"
    pairs, files, notes = context(system)
    batches = [queries[i:i + BATCH] for i in range(0, len(queries), BATCH)]

    def ask(batch):
        for attempt in range(3):
            try:
                answer = extract_json(llm.complete(SYSTEM_PROMPT, prompt(system, batch, pairs, files, notes)))
                missing = [q["id"] for q in batch if q["id"] not in answer]
                if missing:
                    raise RuntimeError(f"no translation for {missing}")
                return {q["id"]: answer[q["id"]] for q in batch}
            except Exception as e:  # a malformed answer is retried; after that, the queries are unsupported
                print(f"{system}: translation attempt {attempt + 1} failed: {e}", file=sys.stderr)
        return {q["id"]: None for q in batch}

    result = {}
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for part in pool.map(ask, batches):
            result.update(part)
    return result, llm.describe()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        queries = json.load(f)["queries"]
    system = sys.argv[2]
    translations, translator = translate(queries, system)
    # A fixed suffix for every query, e.g. the SETTINGS clause that selects the
    # standard semantics in ClickHouse.
    # The rewrite for ClickHouse's string functions (lib/sqlrewrite.py), as
    # for the reference.
    if system_config(system).get("REWRITE", "") == "clickhouse-standard":
        sys.path.insert(0, os.path.join(HERE, "lib"))
        import sqlrewrite
        translations = {k: sqlrewrite.clickhouse_standard(v) if v else v for k, v in translations.items()}
    suffix = system_config(system).get("QUERY_SUFFIX", "")
    if len(suffix) >= 2 and suffix[0] == suffix[-1] == '"':
        suffix = suffix[1:-1]
    out = [{"id": q["id"], "sql": (translations[q["id"]] + " " + suffix).strip()
            if translations.get(q["id"]) else None} for q in queries]
    with open(sys.argv[3], "w") as f:
        json.dump({"system": system, "translator": translator, "queries": out}, f, indent=1, ensure_ascii=False)
    unsupported = sum(1 for q in out if not q["sql"])
    print(f"{system}: translator {translator}, {unsupported} of {len(out)} unsupported", file=sys.stderr)


if __name__ == "__main__":
    main()
