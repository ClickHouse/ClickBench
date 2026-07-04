#!/usr/bin/env python3
# Generate DuckDB query sets from the ClickHouse query sets (../queries/<ds>.sql), applying
# ONLY the translations DuckDB actually needs -- everything else is copied verbatim. Run:
#   ./translate.py            # regenerate queries/<ds>.sql for every dataset
# Keeping this as a script documents exactly which constructs were changed and why.
import os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC  = os.path.join(HERE, "..", "queries")
DST  = os.path.join(HERE, "queries")
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

def translate(sql):
    s = sql
    # multiIf -> CASE (tpcds); if(c,t,f) is native in DuckDB so leave it
    s = transform_calls(s, "multiIf", multiif)
    # date-part extractors -> DuckDB scalar funcs (same 1-arg shape)
    for a, b in [("toYear","year"),("toMonth","month"),("toDayOfMonth","day"),
                 ("toHour","hour"),("toMinute","minute"),("toSecond","second")]:
        s = transform_calls(s, a, (lambda B: (lambda ar: f"{B}({ar[0]})"))(b))
    s = transform_calls(s, "toDayOfWeek", lambda ar: f"isodow({ar[0]})")
    s = transform_calls(s, "toYYYYMM",   lambda ar: f"(year({ar[0]})*100 + month({ar[0]}))")
    # start-of-period -> date_trunc
    for a, unit in [("toStartOfYear","year"),("toStartOfQuarter","quarter"),
                    ("toStartOfMonth","month"),("toStartOfWeek","week"),("toStartOfDay","day"),
                    ("toStartOfHour","hour"),("toStartOfMinute","minute")]:
        s = transform_calls(s, a, (lambda U: (lambda ar: f"date_trunc('{U}', {ar[0]})"))(unit))
    # week-since-epoch (mgbench) approximated with datediff on weeks
    s = transform_calls(s, "toRelativeWeekNum", lambda ar: f"datediff('week', DATE '1970-01-01', {ar[0]})")
    # casts: toDate/toDateTime(x) -> CAST(x AS DATE/TIMESTAMP)
    s = transform_calls(s, "toDateTime", lambda ar: f"CAST({ar[0]} AS TIMESTAMP)")
    s = transform_calls(s, "toDate",     lambda ar: f"CAST({ar[0]} AS DATE)")
    # distinct counts: uniq (approx in CH) -> approx_count_distinct; uniqExact -> exact
    s = transform_calls(s, "uniqExact", lambda ar: f"count(DISTINCT {ar[0]})")
    s = transform_calls(s, "uniq",      lambda ar: f"approx_count_distinct({ar[0]})")
    # count() -> count(*)
    s = re.sub(r'\bcount\(\s*\)', 'count(*)', s, flags=re.IGNORECASE)
    return s

os.makedirs(DST, exist_ok=True)
changed = 0
for ds in DATASETS:
    src = os.path.join(SRC, f"{ds}.sql")
    if not os.path.exists(src): continue
    lines = [l.rstrip("\n") for l in open(src) if l.strip()]
    out = [translate(l) for l in lines]
    open(os.path.join(DST, f"{ds}.sql"), "w").write("\n".join(out) + "\n")
    diff = sum(1 for a, b in zip(lines, out) if a != b)
    changed += diff
    print(f"{ds}: {len(out)} queries, {diff} translated")
print(f"total translated lines: {changed}")
