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

_CLAUSE_KW = {"where","group","order","limit","on","using","join","left","right","inner",
              "full","cross","union","having","offset","fetch","except","intersect"}

def add_subquery_aliases(s):
    """MySQL & PostgreSQL require every FROM/JOIN derived table to be named. Insert `AS _subN`
    after any FROM/JOIN (SELECT ...) whose matching ) is not already followed by an alias."""
    pat = re.compile(r'(?i)(\bFROM\b|\bJOIN\b)\s*\(\s*SELECT\b')
    i = n = 0
    while True:
        m = pat.search(s, i)
        if not m: break
        popen = s.index('(', m.start())
        depth, j = 0, popen
        while j < len(s):
            if s[j] == '(': depth += 1
            elif s[j] == ')':
                depth -= 1
                if depth == 0: break
            j += 1
        k = j + 1
        while k < len(s) and s[k].isspace(): k += 1
        nxt = re.match(r'[A-Za-z_]\w*', s[k:]) if k < len(s) else None
        aliased = bool(nxt) and (nxt.group(0).lower() == "as" or nxt.group(0).lower() not in _CLAUSE_KW)
        if aliased:
            i = j + 1
        else:
            n += 1; alias = f" AS _sub{n}"
            s = s[:j+1] + alias + s[j+1:]; i = j + 1 + len(alias)
    return s

def cast_comma(a):
    # ClickHouse CAST(expr, 'type') -> standard CAST(expr AS type). The AS-form is one arg and
    # passes through. A placeholder avoids transform_calls re-matching the emitted CAST(.
    if len(a) >= 2 and re.match(r"^\s*'.*'\s*$", a[-1], re.S):
        return f"__CAST__({', '.join(a[:-1])} AS {a[-1].strip().strip(chr(39))})"
    return f"__CAST__({', '.join(a)})"

def rollup_to_fn(s):
    """`GROUP BY a, b WITH ROLLUP` (ClickHouse/MySQL) -> `GROUP BY ROLLUP(a, b)` (SQL standard).
    The group list has no parens in our queries, so [^()] safely bounds it to one clause."""
    return re.sub(r'(?i)GROUP BY ([^()]+?) WITH ROLLUP',
                  lambda m: f"GROUP BY ROLLUP({m.group(1).strip()})", s)

_NOT_KW = {"like","in","exists","null","between","any","all","not","true","false"}
def not_int_to_bool(s):
    """PostgreSQL requires a boolean for NOT; ClickHouse allows an int column (0/1). Rewrite
    `NOT <col>` (not NOT LIKE/IN/EXISTS/NULL/...) to `NOT (<col> <> 0)`."""
    def repl(m):
        w = m.group(1)
        return m.group(0) if w.lower() in _NOT_KW else f"NOT ({w} <> 0)"
    return re.sub(r'\bNOT\s+([A-Za-z_]\w*)', repl, s, flags=re.IGNORECASE)

def inline_having_aliases(s):
    """PostgreSQL forbids output aliases in HAVING. Replace alias references there with the
    defining expression, built from `<func>(...) AS <alias>` occurrences in the query."""
    aliases = {}
    for m in re.finditer(r'([A-Za-z_]\w*\s*\((?:[^()]|\([^()]*\))*\))\s+AS\s+([A-Za-z_]\w*)', s):
        aliases[m.group(2)] = m.group(1)
    if not aliases: return s
    def repl(mm):
        clause = mm.group(0)
        for al, expr in aliases.items():
            clause = re.sub(r'\b' + re.escape(al) + r'\b', expr, clause)
        return clause
    return re.sub(r'(?is)\bHAVING\b.*?(?=\bORDER\s+BY\b|\bLIMIT\b|\)|$)', repl, s)

# Per-engine knobs for the few constructs that actually differ across dialects.
# datepart(unit, expr): DuckDB/StarRocks have scalar year()/month()/...; PostgreSQL (CedarDB)
# uses EXTRACT(unit FROM expr).
ENGINES = {
    "duckdb": {
        "timestamp": "TIMESTAMP",                                        # CAST target for toDateTime
        "datepart":  lambda u, e: f"{u}({e})",
        "uniq":      lambda a: f"approx_count_distinct({a[0]})",
        "dow":       lambda a: f"isodow({a[0]})",                         # toDayOfWeek
        "relweek":   lambda a: f"datediff('week', DATE '1970-01-01', {a[0]})",
        "f32": "FLOAT", "f64": "DOUBLE",                                  # CAST AS Float32/Float64
        "rollup": True, "backtick": True,                                # WITH ROLLUP, `id` -> "id"
        "quote_at": True,                                                # `at` is a reserved word
    },
    "starrocks": {
        "timestamp": "DATETIME",
        "datepart":  lambda u, e: f"{u}({e})",
        "uniq":      lambda a: f"approx_count_distinct({a[0]})",
        "dow":       lambda a: f"dayofweek({a[0]})",                      # 1=Sun..7=Sat
        "relweek":   lambda a: f"floor(datediff({a[0]}, '1970-01-01') / 7)",
        "std_dialect": True,                                             # aliased subqueries, USING(), etc.
        "pos":       lambda a: f"instr({a[0]}, {a[1]})",                 # CH position(haystack, needle)
        "f32": "FLOAT", "f64": "DOUBLE",
        "rollup": True,                                                  # ROLLUP() works; keep `backticks`
        "cast_op": True,                                                 # no :: operator; needs CAST()
    },
    "cedardb": {                                                         # PostgreSQL dialect
        "timestamp": "TIMESTAMP",
        "datepart":  lambda u, e: f"EXTRACT({u.upper()} FROM {e})",
        "uniq":      lambda a: f"count(DISTINCT {a[0]})",                 # no approx in PG
        "dow":       lambda a: f"EXTRACT(ISODOW FROM {a[0]})",
        "relweek":   lambda a: f"floor((CAST({a[0]} AS DATE) - DATE '1970-01-01') / 7)",
        "std_dialect": True,
        "ifnull_coalesce": True,                                         # ifnull is type-strict
        "having_inline": True,                                          # no output aliases in HAVING
        "pos":       lambda a: f"strpos({a[0]}, {a[1]})",               # CH position(haystack, needle)
        "f32": "REAL", "f64": "DOUBLE PRECISION",
        "rollup": True, "backtick": True,
        "interval_quote": True,                                         # INTERVAL '3' MONTH
        "not_bool": True,                                               # NOT <intcol> -> NOT (<intcol> <> 0)
        "quote_at": True,
    },
}

def translate(sql, eng):
    E = ENGINES[eng]
    s = sql
    s = transform_calls(s, "multiIf", multiif)                           # -> CASE (tpcds); if() stays native
    for a, unit in [("toYear","year"),("toMonth","month"),("toDayOfMonth","day"),
                    ("toHour","hour"),("toMinute","minute"),("toSecond","second")]:
        s = transform_calls(s, a, (lambda U: (lambda ar: E["datepart"](U, ar[0])))(unit))
    s = transform_calls(s, "toDayOfWeek", E["dow"])
    s = transform_calls(s, "toYYYYMM",   lambda ar: f"({E['datepart']('year', ar[0])}*100 + {E['datepart']('month', ar[0])})")
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
    # Constructs every engine needs adjusted from the ClickHouse form:
    s = transform_calls(s, "Nullable", lambda a: a[0])                   # CAST AS Nullable(T) -> T
    s = transform_calls(s, "CAST", cast_comma); s = s.replace("__CAST__", "CAST")  # CAST(x,'t')->CAST(x AS t)
    s = re.sub(r'(?i)\bsubstring\(\s*([^()]+?)\s+FROM\s+([^()]+?)\s+FOR\s+([^()]+?)\s*\)', r'substring(\1, \2, \3)', s)
    s = re.sub(r'(?i)\bsubstring\(\s*([^()]+?)\s+FROM\s+([^()]+?)\s*\)', r'substring(\1, \2)', s)
    s = transform_calls(s, "notEmpty", lambda a: f"({a[0]} <> '')")
    s = transform_calls(s, "empty",    lambda a: f"({a[0]} = '')")
    s = re.sub(r"\(([^()?]+)\)\s*\?\s*([^:?]+?)\s*:\s*('[^']*'|[\w.]+)",   # (cond) ? a : b -> CASE
               r"CASE WHEN (\1) THEN \2 ELSE \3 END", s)
    s = transform_calls(s, "any", lambda a: f"any_value({a[0]})")        # any() aggregate
    s = re.sub(r'\bFloat32\b', E["f32"], s, flags=re.IGNORECASE)          # CAST AS Float32/Float64
    s = re.sub(r'\bFloat64\b', E["f64"], s, flags=re.IGNORECASE)
    if E.get("rollup"):    s = rollup_to_fn(s)                           # WITH ROLLUP -> ROLLUP()
    if E.get("backtick"):  s = s.replace('`', '"')                       # `id` -> "id" (not StarRocks)
    if E.get("interval_quote"):                                          # INTERVAL 3 MONTH -> INTERVAL '3' MONTH
        s = re.sub(r'(?i)\bINTERVAL\s+([0-9]+)\s+(DAY|MONTH|YEAR|WEEK|HOUR|MINUTE|SECOND)S?\b',
                   lambda m: f"INTERVAL '{m.group(1)}' {m.group(2).upper()}", s)
    if E.get("not_bool"):  s = not_int_to_bool(s)
    if E.get("cast_op"):                                                 # expr::Type -> CAST(expr AS Type)
        s = re.sub(r"([\w.]+|'[^']*')::([A-Za-z]\w*(?:\([0-9, ]*\))?)", r"CAST(\1 AS \2)", s)
    if E.get("quote_at"):                                                # `at` reserved: alias -> "at"
        s = re.sub(r'\bAS at\b', 'AS "at"', s); s = re.sub(r'\bat\.', '"at".', s)
    # MySQL/PostgreSQL dialect adjustments (DuckDB accepts the ClickHouse forms as-is).
    if E.get("std_dialect"):
        s = transform_calls(s, "replaceOne", lambda a: f"replace({a[0]}, {a[1]}, {a[2]})")
        s = transform_calls(s, "position",   lambda a: E["pos"](a) if len(a) == 2 else f"__position__({', '.join(a)})")
        s = re.sub(r'(?i)\bUSING\s+([A-Za-z_]\w*)', r'USING (\1)', s)     # USING col -> USING (col)
        s = add_subquery_aliases(s)
    if E.get("ifnull_coalesce"):
        s = transform_calls(s, "ifNull", lambda a: f"coalesce({', '.join(a)})")
    if E.get("having_inline"):
        s = inline_having_aliases(s)
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
