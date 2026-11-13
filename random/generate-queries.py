#!/usr/bin/env python3
"""Generates the random queries of a benchmark run with a language model.

Usage:
  generate-queries.py --seed <seed> --sample-db <dir> --sample-parquet <glob> --output queries.json
                      [--count 100] [--batches 8] [--per-batch 30]

Entropy. The model is not asked for "random queries" only: sampling
parameters are not available on the current models, and a model asked the
same thing twice tends to answer the same. Every batch gets its own prompt,
drawn with a PRNG seeded by --seed: a persona, the SQL features it must use
and in what proportion, a subset of columns to prefer, a few unrelated words
to start from, and a random nonce. The batches together make several times
more candidates than needed, and the final set is a sample of them.

Validation. Every candidate runs on the sample database (the same kind of
generated data, but small) with the pinned ClickHouse and the reference
settings, and is dropped if it
  - is not a single SELECT with an ORDER BY,
  - aggregates large integers with SUM/AVG (the results depend on overflow),
  - fails, takes too long, or returns no rows or more than 100 rows,
  - returns different results with different numbers of threads and block
    sizes, which means that its result is not determined (an ORDER BY with
    ties, an arbitrary LIMIT),
  - returns a different result in DuckDB on the same sample (compared as the
    results of the systems are, lib/validate.py), or fails there: a second
    implementation of the standard catches the queries on which ClickHouse,
    the reference, is wrong or deviates from the standard, and the ones whose
    meaning is ambiguous.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "lib"))
import llm  # noqa: E402
import reference  # noqa: E402
import sqlrewrite  # noqa: E402
import validate  # noqa: E402

CLICKBENCH = os.path.dirname(HERE)

FEATURES = {
    "join": "an explicit JOIN (self-join of hits through derived tables or CTEs: INNER, LEFT, RIGHT, FULL OUTER)",
    "in_subquery": "IN or NOT IN with a subquery",
    "exists": "EXISTS or NOT EXISTS",
    "scalar_subquery": "a scalar subquery in SELECT or WHERE",
    "correlated_subquery": "a correlated subquery (referencing the outer query)",
    "window": "window functions (ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD, running SUM/COUNT with OVER (PARTITION BY ... ORDER BY ...), frames)",
    "cte": "WITH (common table expressions), possibly several and referencing each other",
    "derived_table": "a subquery in FROM",
    "group_by_having": "GROUP BY with HAVING",
    "case": "CASE expressions, conditional aggregation (SUM(CASE ...), COUNT(*) FILTER-like with CASE)",
    "set_operation": "UNION, UNION ALL, INTERSECT or EXCEPT",
    "count_distinct": "COUNT(DISTINCT ...)",
    "string_functions": "string functions and LIKE (CHAR_LENGTH, LOWER, UPPER, SUBSTRING(s, start, length), TRIM, ||, LIKE patterns)",
    "date_time": "date and time arithmetic (EXTRACT, DATE_TRUNC, comparison of dates, intervals)",
    "multi_level": "several levels of nested aggregation (aggregate over the result of an aggregate)",
    "top_n_per_group": "top-N per group",
}

PERSONAS = [
    "a marketing analyst looking for campaign effectiveness",
    "an SRE investigating anomalies in traffic",
    "a fraud analyst looking for bots and suspicious users",
    "a product manager studying user retention and sessions",
    "an SEO specialist studying search phrases and referers",
    "a data scientist preparing features for a model",
    "a content editor studying which pages are popular",
    "an ad-tech engineer checking advertising engines and click attribution",
    "a performance engineer looking at page timings",
    "a mobile team lead comparing mobile and desktop traffic",
    "a growth hacker studying funnels and conversion",
    "a security engineer looking at IP networks and regions",
    "a BI developer building a weekly dashboard",
    "a researcher studying the long tail of rare events",
]

WORDS = """amber anvil aurora basalt beacon bramble cascade cinder cobalt comet coral
crescent delta drift ember fjord flint garnet glacier harbor hazel indigo iris jasper
juniper kelp lagoon lantern lichen marble meadow meteor nectar nimbus obsidian onyx
orchid pebble prism quartz quill raven reef saffron sable sierra solstice spruce
talon thistle tundra umber velvet vortex willow yarrow zenith zephyr""".split()

# Columns that hold large integers (identifiers, hashes, addresses):
# SUM/AVG over them depend on overflow handling and floating-point rounding.
LARGE_INTEGER_COLUMNS = ["WatchID", "UserID", "FUniqID", "RefererHash", "URLHash", "ClientIP",
                         "RemoteIP", "IPNetworkID", "CounterID", "RegionID", "HID", "WindowName",
                         "OpenerName", "ParamPrice", "CodeVersion", "CLID"]

SYSTEM_PROMPT = """You write analytical SQL queries for a database benchmark. The queries are run on many
different database systems, and their results are compared with each other, so they
must be portable and their results must be fully determined."""

RULES = """Rules, all mandatory:

1. The only table is `hits`. Its schema is below. Use self-joins,
   derived tables and CTEs over `hits` to make joins.
2. Write portable SQL that runs in ClickHouse, DuckDB and PostgreSQL alike: standard
   syntax, standard functions (COUNT, SUM, AVG, MIN, MAX, COUNT(DISTINCT), CASE, COALESCE,
   NULLIF, CAST, ABS, ROUND, FLOOR, CHAR_LENGTH, LOWER, UPPER, SUBSTRING(s, start, length),
   TRIM, ||, LIKE, EXTRACT(... FROM ...), DATE_TRUNC('unit', t), window functions).
   No vendor-specific functions or syntax. The text is in several languages, so
   string functions must count characters: CHAR_LENGTH, not LENGTH; SUBSTRING
   with commas, not SUBSTRING ... FROM ... FOR; no POSITION, LEFT, RIGHT, REVERSE.
3. The result must be fully determined: end with an ORDER BY that orders the rows
   completely (list enough keys to break every tie; it is fine to order by all
   output columns), and every LIMIT must be preceded by such an ORDER BY, also
   inside subqueries. No queries whose result depends on the order of reading.
   Ties are common: the data consists of several copies of a base dataset with
   the identifiers and strings transformed differently in every copy, so groups
   often have exactly the same counts and sums. Always break ties with keys.
4. The result has from 1 to 100 rows. Use LIMIT 100 or less, or aggregate to few rows.
5. No SUM or AVG over large integers (identifiers, hashes, IP addresses:
   """ + ", ".join(LARGE_INTEGER_COLUMNS) + """), and nothing else that can overflow
   or depend on the precision of floating-point arithmetic. SUM/AVG over small
   quantities (flags, widths, timings, counts) are fine.
6. No integer division: write CAST(x AS DOUBLE PRECISION) / y. No division by zero:
   use NULLIF(y, 0).
7. ORDER BY keys must not be NULL (wrap them in COALESCE if they can be). Prefer
   numeric ORDER BY keys; a string key is fine as a tie-breaker.
8. The data is anonymized: the values of identifiers (CounterID, UserID, RegionID...)
   are random, strings are random text that keeps the shape of the original
   (URLs look like URLs, search phrases are words), dates are in July 2013, and
   small integers keep their meaning (0/1 flags, small codes). Do not filter on
   specific identifier values or specific strings; filter on properties
   (SearchPhrase <> '', IsRefresh = 0, ResolutionWidth > 1000, a date range in July
   2013, LIKE '%.html%'), or on values computed by a subquery (the busiest counter).
   Make sure the filters keep enough rows for a non-empty result.
9. Queries must be feasible at the scale of a billion rows: no cross joins without
   selective conditions, join derived tables that are already aggregated or filtered
   to a moderate size.
10. Make every query different from the others and from the standard ClickBench
   queries: different goals, columns, shapes and features. Include queries of
   varied complexity, from simple to very complex.
11. Output aliases must be simple identifiers without quotes.
"""


def column_list():
    structure = reference.create_table_sql()
    columns = re.findall(r"^\s+(\w+) (.+?) NOT NULL", structure, re.M)
    return columns


def batch_prompt(rng, batch, per_batch, seed):
    columns = column_list()
    names = [c for c, _ in columns]
    features = list(FEATURES)
    rng.shuffle(features)
    focus = features[: rng.randint(3, 6)]
    preferred = rng.sample(names, rng.randint(12, 24))
    persona = rng.choice(PERSONAS)
    words = rng.sample(WORDS, 4)
    nonce = hashlib.sha256(f"{seed}/{batch}".encode()).hexdigest()[:24]
    schema = "\n".join(f"  {c} {t}" for c, t in columns)
    with open(os.path.join(CLICKBENCH, "clickhouse", "queries.sql")) as f:
        examples = f.read()
    quota = "\n".join(f"  - {FEATURES[f]}: at least {max(2, per_batch // len(focus) // 2)} queries"
                      for f in focus)
    return f"""Write {per_batch} new SQL queries.

Randomness: this is batch {batch} of a randomized benchmark, random nonce {nonce}.
Use the nonce and these words as a source of randomness for your choices of
topics, columns, constants and shapes: {", ".join(words)}. Avoid the most obvious
queries; surprise the reader. Imagine that the queries are written by {persona}.

This batch must emphasize:
{quota}
The rest of the batch may use any features, including the ones above:
{", ".join(FEATURES[f].split(" (")[0] for f in features[len(focus):])}.
Prefer these columns (but use others too): {", ".join(preferred)}.

{RULES}
The schema of `hits`:
{schema}

For reference only, these are the standard ClickBench queries (do not repeat them):
{examples}

Answer with a JSON array, nothing else. Every element is an object
{{"sql": "<one SELECT statement on one line, without a trailing semicolon>",
  "features": [<the names of the features it uses, from: {", ".join(FEATURES)}>],
  "description": "<what it computes, one sentence>"}}
"""


def extract_json(text):
    text = text.strip()
    match = re.search(r"```(?:json)?\s*(\[.*\])\s*```", text, re.S)
    if match:
        text = match.group(1)
    else:
        start, end = text.find("["), text.rfind("]")
        text = text[start:end + 1]
    return json.loads(text)


def normalize(sql):
    return re.sub(r"\s+", " ", sql.strip().rstrip(";")).strip()


LARGE_AGGREGATE = re.compile(
    r"\b(SUM|AVG)\s*\(\s*(DISTINCT\s+)?(\w+\.)?(" + "|".join(LARGE_INTEGER_COLUMNS) + r")\b", re.I)


def static_check(sql):
    upper = sql.upper()
    if not re.match(r"^\s*(SELECT|WITH)\b", sql, re.I):
        return "not a SELECT"
    if ";" in sql:
        return "several statements"
    if "ORDER BY" not in upper:
        return "no ORDER BY"
    if LARGE_AGGREGATE.search(sql):
        return "SUM/AVG over large integers"
    return sqlrewrite.unsupported(sql)


def dynamic_check(db, sql, time_limit):
    """Runs the query twice with different parallelism; returns (error, seconds, rows)."""
    status, seconds, first, error = reference.run_query(
        db, sql, settings=["--max_threads=1"], timeout=time_limit)
    if status != "ok":
        return f"{status}: {error.splitlines()[0] if error else ''}"[:300], seconds, 0
    rows = first.count(b"\n") - 1  # without the header
    if rows == 0:
        return "empty result", seconds, rows
    if rows > 100:
        return f"{rows} rows", seconds, rows
    status, _, second, error = reference.run_query(
        db, sql, settings=["--max_threads=16", "--max_block_size=1000",
                           "--join_algorithm=parallel_hash"],
        timeout=time_limit)
    if status != "ok":
        return f"second run: {status}", seconds, rows
    if first != second:
        return "nondeterministic", seconds, rows
    if duckdb_connection is not None:
        reason = duckdb_check(sql, first, time_limit)
        if reason:
            return reason, seconds, rows
    return None, seconds, rows


# DuckDB on the sample, for the cross-check (see the docstring).
duckdb_connection = None


def open_duckdb(parquet_glob):
    import duckdb
    global duckdb_connection
    duckdb_connection = duckdb.connect()
    duckdb_connection.execute("SET TimeZone = 'UTC'")
    duckdb_connection.execute(f"CREATE VIEW hits AS SELECT * FROM read_parquet('{parquet_glob}')")


def duckdb_check(sql, reference_output, time_limit):
    import threading
    timer = threading.Timer(time_limit, duckdb_connection.interrupt)
    timer.start()
    try:
        cursor = duckdb_connection.execute(sql)
        names = [d[0] for d in cursor.description]
        rows = cursor.fetchall()
    except Exception as e:  # any failure: the query is not portable to DuckDB
        return f"DuckDB: {str(e).splitlines()[0][:200]}"
    finally:
        timer.cancel()

    def text(v):
        return "NULL" if v is None else str(v)
    output = "\n".join([",".join(names)] + [",".join(text(v) for v in r) for r in rows]) + "\n"
    status, detail = validate.compare(validate.parse_reference(reference_output), output.encode())
    return None if status == "ok" else f"DuckDB disagrees: {detail[:150]}"


def select(candidates, count, rng):
    """Picks `count` candidates, covering the features as evenly as possible."""
    pool = candidates[:]
    rng.shuffle(pool)
    chosen, coverage = [], {f: 0 for f in FEATURES}
    while pool and len(chosen) < count:
        best = max(pool, key=lambda c: sum(1.0 / (1 + coverage.get(f, 0)) for f in c["features"]))
        pool.remove(best)
        chosen.append(best)
        for f in best["features"]:
            coverage[f] = coverage.get(f, 0) + 1
    return chosen, coverage


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", required=True)
    parser.add_argument("--sample-db", required=True)
    parser.add_argument("--sample-parquet", required=True,
                        help="the files of the sample (canonical/part_*.parquet), for DuckDB")
    parser.add_argument("--output", required=True)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--batches", type=int, default=8)
    parser.add_argument("--per-batch", type=int, default=30)
    parser.add_argument("--time-limit", type=int, default=20,
                        help="seconds a query may take on the sample")
    parser.add_argument("--parallel", type=int, default=8)
    args = parser.parse_args()

    open_duckdb(args.sample_parquet)
    rng = random.Random(hashlib.sha256(args.seed.encode()).digest())
    prompts = [batch_prompt(rng, b, args.per_batch, args.seed) for b in range(args.batches)]

    def ask(prompt):
        for attempt in range(3):
            try:
                return extract_json(llm.complete(SYSTEM_PROMPT, prompt))
            except Exception as e:  # a malformed answer is retried, then the batch is lost
                print(f"generation attempt {attempt + 1} failed: {e}", file=sys.stderr)
        return []

    start = time.time()
    with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
        batches = list(pool.map(ask, prompts))
    print(f"Generated {sum(map(len, batches))} candidates in {time.time() - start:.0f} s "
          f"with {llm.describe()}", file=sys.stderr)

    seen, candidates, rejected = set(), [], {}
    for b, batch in enumerate(batches):
        for item in batch:
            if not isinstance(item, dict) or not isinstance(item.get("sql"), str):
                continue
            sql = normalize(item["sql"])
            if sql.lower() in seen:
                rejected["duplicate"] = rejected.get("duplicate", 0) + 1
                continue
            seen.add(sql.lower())
            reason = static_check(sql)
            if reason is None:
                reason, seconds, rows = dynamic_check(args.sample_db, sql, args.time_limit)
            if reason:
                key = reason.split(":")[0]
                rejected[key] = rejected.get(key, 0) + 1
                print(f"rejected ({reason}): {sql[:200]}", file=sys.stderr)
                continue
            features = [f for f in item.get("features", []) if f in FEATURES]
            candidates.append({"sql": sql, "features": features,
                               "description": str(item.get("description", "")),
                               "batch": b, "sample_rows": rows, "sample_time": round(seconds, 3)})

    print(f"{len(candidates)} candidates passed, rejected: {json.dumps(rejected)}", file=sys.stderr)
    if len(candidates) < args.count:
        sys.exit(f"Only {len(candidates)} valid candidates for {args.count} queries")

    chosen, coverage = select(candidates, args.count, rng)
    queries = [dict(id=f"q{i + 1:03d}", **c) for i, c in enumerate(chosen)]
    with open(args.output, "w") as f:
        json.dump({"seed": args.seed, "model": llm.describe(), "generated": sum(map(len, batches)),
                   "valid": len(candidates), "rejected": rejected, "coverage": coverage,
                   "queries": queries}, f, indent=1, ensure_ascii=False)
    print(f"Wrote {len(queries)} queries, feature coverage: {json.dumps(coverage)}", file=sys.stderr)


if __name__ == "__main__":
    main()
