#!/usr/bin/env python3
# Generate per-engine query sets from the ClickHouse query sets (versions/queries/<ds>.sql),
# applying ONLY the translations each engine needs -- everything else is copied verbatim.
#
#   ./translate.py [duckdb|starrocks|cedardb ...]     # default: all three
#
# Output goes to versions/<engine>/queries/<ds>.sql. Keeping this as a script documents
# exactly which constructs were changed per engine and why. tpch and job are standard SQL
# and come out unchanged on every engine.
import os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))          # versions/
SRC  = os.path.join(ROOT, "queries")
DATASETS = ["mgbench","ssb","hits","uk","ontime","taxi","coffeeshop","tpch","tpcds","job"]

def split_args(s):
    """Split a function argument string on top-level commas (respect parens/quotes)."""
    out, depth, cur, q = [], 0, "", None
    for ch in s:
        if q:
            cur += ch
            if ch == q: q = None
        elif ch in "'\"":
            q = ch; cur += ch
        elif ch == "(":
            depth += 1; cur += ch
        elif ch == ")":
            depth -= 1; cur += ch
        elif ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    out.append(cur)
    return [a.strip() for a in out]

def transform_calls(sql, name, fn):
    """Replace every call NAME(...) (word-boundary, case-insensitive) using fn(args)->str.
    Re-scans after each replacement, so nested calls are handled outermost-first."""
    pat = re.compile(r'\b' + re.escape(name) + r'\s*\(', re.IGNORECASE)
    while True:
        m = pat.search(sql)
        if not m: return sql
        i = m.end() - 1          # index of '('
        depth, j = 0, i
        while j < len(sql):
            if sql[j] == "(": depth += 1
            elif sql[j] == ")":
                depth -= 1
                if depth == 0: break
            j += 1
        args = split_args(sql[i+1:j])
        sql = sql[:m.start()] + fn(args) + sql[j+1:]

def multiif(args):
    # multiIf(c1,v1,c2,v2,...,else) -> CASE WHEN c1 THEN v1 ... ELSE else END
    parts, i = [], 0
    while i + 1 < len(args):
        parts.append(f"WHEN {args[i]} THEN {args[i+1]}"); i += 2
    els = args[i] if i < len(args) else "NULL"
    return "CASE " + " ".join(parts) + f" ELSE {els} END"

# Per-engine knobs for the few constructs that actually differ across dialects.
ENGINES = {
    "duckdb": {
        "timestamp": "TIMESTAMP",                                        # CAST target for toDateTime
        "uniq":      lambda a: f"approx_count_distinct({a[0]})",
        "dow":       lambda a: f"isodow({a[0]})",                         # toDayOfWeek
        "relweek":   lambda a: f"datediff('week', DATE '1970-01-01', {a[0]})",
    },
    "starrocks": {
        "timestamp": "DATETIME",
        "uniq":      lambda a: f"approx_count_distinct({a[0]})",
        "dow":       lambda a: f"dayofweek({a[0]})",                      # 1=Sun..7=Sat
        "relweek":   lambda a: f"floor(datediff({a[0]}, '1970-01-01') / 7)",
    },
    "cedardb": {                                                         # PostgreSQL dialect
        "timestamp": "TIMESTAMP",
        "uniq":      lambda a: f"count(DISTINCT {a[0]})",                 # no approx in PG
        "dow":       lambda a: f"EXTRACT(ISODOW FROM {a[0]})",
        "relweek":   lambda a: f"floor((CAST({a[0]} AS DATE) - DATE '1970-01-01') / 7)",
    },
}

def translate(sql, eng):
    E = ENGINES[eng]
    s = sql
    s = transform_calls(s, "multiIf", multiif)                           # -> CASE (tpcds); if() stays native
    for a, b in [("toYear","year"),("toMonth","month"),("toDayOfMonth","day"),
                 ("toHour","hour"),("toMinute","minute"),("toSecond","second")]:
        s = transform_calls(s, a, (lambda B: (lambda ar: f"{B}({ar[0]})"))(b))
    s = transform_calls(s, "toDayOfWeek", E["dow"])
    s = transform_calls(s, "toYYYYMM",   lambda ar: f"(year({ar[0]})*100 + month({ar[0]}))")
    for a, unit in [("toStartOfYear","year"),("toStartOfQuarter","quarter"),
                    ("toStartOfMonth","month"),("toStartOfWeek","week"),("toStartOfDay","day"),
                    ("toStartOfHour","hour"),("toStartOfMinute","minute")]:
        s = transform_calls(s, a, (lambda U: (lambda ar: f"date_trunc('{U}', {ar[0]})"))(unit))
    s = transform_calls(s, "toRelativeWeekNum", E["relweek"])
    s = transform_calls(s, "toDateTime", (lambda T: (lambda ar: f"CAST({ar[0]} AS {T})"))(E["timestamp"]))
    s = transform_calls(s, "toDate",     lambda ar: f"CAST({ar[0]} AS DATE)")
    s = transform_calls(s, "uniqExact",  lambda ar: f"count(DISTINCT {ar[0]})")
    s = transform_calls(s, "uniq",       E["uniq"])
    s = re.sub(r'\bcount\(\s*\)', 'count(*)', s, flags=re.IGNORECASE)     # count() -> count(*)
    return s

targets = sys.argv[1:] or list(ENGINES)
for eng in targets:
    if eng not in ENGINES: sys.exit(f"unknown engine: {eng}")
    dst = os.path.join(ROOT, eng, "queries"); os.makedirs(dst, exist_ok=True)
    changed = 0
    for ds in DATASETS:
        src = os.path.join(SRC, f"{ds}.sql")
        if not os.path.exists(src): continue
        lines = [l.rstrip("\n") for l in open(src) if l.strip()]
        out = [translate(l, eng) for l in lines]
        open(os.path.join(dst, f"{ds}.sql"), "w").write("\n".join(out) + "\n")
        changed += sum(1 for a, b in zip(lines, out) if a != b)
    print(f"{eng}: wrote {dst} ({changed} lines translated)")
