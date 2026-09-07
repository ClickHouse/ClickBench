#!/usr/bin/env python3
"""Compare the query-results/ dumps across systems and say where engines actually disagree.

No system is the reference. Every block for a query is grouped by what it returned.

A raw diff is useless here: engines spell the same value differently, and the differences are not
all the same kind of thing. Each query gets the WEAKEST level at which all systems agree:

  IDENTICAL   byte-equal blocks.
  SAME        equal once numbers are canonicalised (trailing zeros, exponent form, -0).
  ORDER       same rows, different order. Usually a ROLLUP total row: its group keys are NULL,
              and the MySQL-family engines sort NULLs first in an ASC ORDER BY where the
              PostgreSQL-family sort them last. Only meaningful where ORDER BY is not total.
  SCALE       one side is the other truncated or rounded to fewer DECIMAL PLACES, so the engines
              computed the same value and declared a narrower result type.
  DIFF_BELOW_<n>  the numbers differ by no more than the --max-diff of <n> that was passed, so
              they were accepted as agreeing. Absent unless --max-diff is given.
  RECORDED    listed in recorded-issues.txt with an established cause, so it is not DIFFER.
              The category from that file is shown instead.
  PADDING     the strings are equal once NUL padding is removed: ClickHouse's FixedString(N)
              padding surviving inside a concatenation, one value spelled two ways.
  ROUNDING    the numbers are adjacent at the coarser side's scale -- exactly one unit in its
              last place -- which is one engine truncating where another rounded.
  TRUNCATED   one side reported ZERO decimal places for a value that has a fractional part, so
              the fraction was discarded rather than narrowed. Every instance found so far is
              int/int division: CedarDB truncates it, Firebolt rounds it, and the other four
              promote to a fractional type.
  PRECISION   numbers that differ by more than the narrower scale explains, agreeing to at least
              --sig significant digits.
  DIFFER      anything else: different row counts, a non-numeric mismatch, or numbers that
              disagree too early to be either of the above.

Decimal places are counted on what the engine PRINTED, before trailing zeros are stripped.

Statuses are compared too: a system that timed out and one that answered do not "agree".
"""
import argparse, collections, datetime, decimal, math, pathlib, re, sys

HDR = '=== '
NUMERIC = re.compile(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$')
RANK = {'IDENTICAL': 0, 'SAME': 0, 'RECORDED': 1, 'ORDER': 1, 'NULLORDER': 1, 'PADDING': 2, 'SCALE': 2,
        'ROUNDING': 3, 'PRECISION': 4, 'TRUNCATED': 5, 'DIFFER': 6}
DIFF_BELOW_RANK = 3     # --max-diff names its own verdict, DIFF_BELOW_<threshold>, ranked here
MATCH_SIG = 5          # significant digits used to pair rows up, not to judge them
# Truncation plus the three roundings engines actually use. Anything one of these produces is the
# same value at a coarser scale; anything none of them produces is a different value.
ROUNDINGS = (decimal.ROUND_DOWN, decimal.ROUND_UP,
             decimal.ROUND_HALF_UP, decimal.ROUND_HALF_EVEN)

def load_recorded(path):
    """-> {(bench, query): (category, note)} from recorded-issues.txt."""
    out = {}
    if not path or not pathlib.Path(path).exists():
        return out
    for line in pathlib.Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        f = line.split(None, 3)
        if len(f) >= 3:
            out[(f[0], f[1])] = (f[2], f[3] if len(f) > 3 else '')
    return out

def parse(path):
    """-> {system: {'status':..., 'rows': [...], 'version':...}}"""
    out, sysname, meta, rows = {}, None, {}, []
    for line in path.read_text().split('\n'):
        if line.startswith(HDR):
            if sysname:
                out[sysname] = dict(meta, rows=rows)
            f = [x.strip() for x in line[len(HDR):].split(' | ')]
            sysname = f[0]
            meta = {'status': 'unknown', 'version': ''}
            for x in f[1:]:
                if x.startswith('status='):
                    meta['status'] = x[7:]
                elif not x.startswith('rows=') and not re.match(r'^\d{4}-\d\d-\d\dT', x):
                    meta['version'] = x
            rows = []
        elif sysname and line != '' and not line.startswith('# '):
            rows.append(line)
    if sysname:
        out[sysname] = dict(meta, rows=rows)
    return out

def canon_num(field):
    if not NUMERIC.match(field):
        return field
    try:
        d = decimal.Decimal(field).normalize()
    except decimal.InvalidOperation:
        return field
    if d == 0:
        return '0'
    return format(d, 'f')

def canon_row(row):
    return '\t'.join(canon_num(f) for f in row.split('\t'))

def decimals(d):
    return max(0, -d.as_tuple().exponent)

def scale_explained(x, y):
    """Is the shorter-scale value the longer one truncated or rounded to that scale?"""
    dx, dy = decimals(x), decimals(y)
    if dx == dy:
        return False
    short, wide, places = (x, y, dx) if dx < dy else (y, x, dy)
    q = decimal.Decimal(1).scaleb(-places)
    for rounding in ROUNDINGS:
        try:
            if wide.quantize(q, rounding=rounding) == short:
                return True
        except decimal.InvalidOperation:
            return False
    return False

def sig_digits(x, y):
    """Significant digits to which two Decimals agree."""
    if x == y:
        return 99
    scale = max(abs(x), abs(y))
    if scale == 0:
        return 99
    rel = abs(x - y) / scale
    return math.floor(-math.log10(float(rel))) if rel > 0 else 99

def representative(members, got):
    """The raw rows of the group member with the longest spelling.

    A group's members are canonically equal, so any of them states the group's value -- but they
    can still print it to different widths. The longest spelling makes the SCALE test as strict as
    the group allows.
    """
    return max((got[s]['rows'] for s in members), key=lambda rows: sum(len(r) for r in rows))

def match_key(canon_row, sig=MATCH_SIG):
    """A row's identity for PAIRING purposes only, numbers coarsened to `sig` significant digits.

    Pairing has to survive the scale differences: an ORDER test that demands exact rows cannot see
    that Doris returned the same rows as CedarDB when it also printed 4 decimal places instead of
    21. Coarsening is safe here because it only decides which row to compare against which -- the
    pair is then judged by the strict field pass, so nothing is excused by being paired.
    """
    out = []
    for f in canon_row.split('\t'):
        if NUMERIC.match(f):
            try:
                out.append(f'{float(f):.{sig}g}')
                continue
            except ValueError:
                pass
        out.append(f)
    return '\t'.join(out)

def text_key(canon_row):
    """A row's non-numeric fields: its identity, for pairing and for row-set comparison.

    NULs are dropped: ClickHouse pads FixedString(N) and the padding survives inside a
    concatenation, so 'Benson\\0\\0...\\0, Floyd' and 'Benson, Floyd' are one row spelled two ways.
    """
    return '\t'.join(f.replace('\0', '') for f in canon_row.split('\t') if not NUMERIC.match(f))

def compare_rows(ra, rb, ca, cb, o):
    """-> (verdict, detail, example).

    ra/rb are the rows as the engines printed them, ca/cb the canonicalised ones. Structure and
    equality come from the canonical rows; decimal places are read off the raw ones.
    """
    if ca == cb:
        return 'SAME', None, None
    if sorted(ca) == sorted(cb):
        return 'ORDER', None, None
    if len(ca) != len(cb):
        return 'DIFFER', None, f'{len(ca)} rows vs {len(cb)} rows'

    verdict = field_pass(ra, rb, ca, cb, o)
    if verdict[0] != 'DIFFER':
        return verdict

    # Row n vs row n differed, but the rows may just be in another order -- a ROLLUP total row
    # sorts first or last depending on the engine's NULL ordering. Re-pair and judge again: coarse
    # numeric key, then string columns alone (0.76 and 0.7685053902 share no numeric key). Only if
    # every row finds a partner, and for the string key only if those columns are unique.
    for keyfn, unique_required in ((match_key, False), (text_key, True)):
        ka, kb = [keyfn(c) for c in ca], [keyfn(c) for c in cb]
        if sorted(ka) != sorted(kb):
            continue
        if unique_required and len(set(ka)) != len(ka):
            continue
        ia = sorted(range(len(ka)), key=lambda i: ka[i])
        ib = sorted(range(len(kb)), key=lambda i: kb[i])
        v, detail, ex = field_pass([ra[i] for i in ia], [rb[i] for i in ib],
                                   [ca[i] for i in ia], [cb[i] for i in ib], o)
        if v == 'SAME':
            return 'ORDER', None, None
        if v != 'DIFFER':
            return v, f'reordered, {detail}' if detail else 'reordered', ex
    # A ROLLUP total row has NULL group keys, so where it sorts decides which rows a LIMIT keeps:
    # one side's window fills with NULL rows and the other's with the data rows they displaced.
    # Recognised only when the row counts match and the rows unique to one side are ALL
    # NULL-bearing -- q037 differs in row count (354 vs 455), so integer division stays DIFFER.
    if o.ignore_null_order and len(ca) == len(cb):
        # Identity is the TEXT columns: the families print numbers at different scales, so a key
        # including them calls dozens of rows unique when only one is. Counted, not set-ed, because
        # a window that is entirely NULL rows repeats one key.
        ka = [text_key(c) for c in ca]
        kb = [text_key(c) for c in cb]
        na, nb = collections.Counter(ka), collections.Counter(kb)
        ua, ub = list((na - nb).elements()), list((nb - na).elements())
        if (ua and all('<NULL>' in k for k in ua)) or (ub and all('<NULL>' in k for k in ub)):
            pa, pb = collections.defaultdict(list), collections.defaultdict(list)
            for r, c, k in zip(ra, ca, ka): pa[k].append((r, c))
            for r, c, k in zip(rb, cb, kb): pb[k].append((r, c))
            sa, sb = [], []
            for k in sorted(set(pa) & set(pb)):
                n = min(len(pa[k]), len(pb[k]))
                sa += pa[k][:n]; sb += pb[k][:n]
            n_moved = max(len(ua), len(ub))
            if not sa:
                # Windows are disjoint, so nothing can be cross-checked: one side's rows are all
                # NULL-keyed and the other's are the data rows they displaced. Accepted on that
                # signature alone, and said so in the detail.
                return 'NULLORDER', f'{n_moved} rows, all NULL-bearing, no overlap', None
            v = field_pass([x[0] for x in sa], [x[0] for x in sb],
                           [x[1] for x in sa], [x[1] for x in sb], o)[0]
            if v != 'DIFFER':
                return 'NULLORDER', f'{n_moved} rows, all NULL-bearing, {len(sa)} shared agree', None
    return verdict

def field_pass(ra, rb, ca, cb, o):
    """Worst field-level verdict comparing row n of one answer against row n of the other."""
    worst = ('SAME', None, None)
    for i, (x, y, cx, cy) in enumerate(zip(ra, rb, ca, cb)):
        if cx == cy:
            continue
        fa, fb = x.split('\t'), y.split('\t')
        if len(fa) != len(fb):
            return 'DIFFER', None, f'line {i+1}: {len(fa)} columns vs {len(fb)}'
        for u, v, cu, cv in zip(fa, fb, cx.split('\t'), cy.split('\t')):
            if cu == cv:
                continue
            if not (NUMERIC.match(u) and NUMERIC.match(v)):
                # ClickHouse pads FixedString(N) and the padding survives a concatenation, so
                # 'Benson\0\0...\0, Floyd' is 'Benson, Floyd' with padding, not another value.
                if u.replace('\0', '') == v.replace('\0', ''):
                    cand = ('PADDING', f'{u.count(chr(0))} NULs', f'line {i+1}')
                    if RANK[cand[0]] > RANK[worst[0]]:
                        worst = cand
                    continue
                return 'DIFFER', None, f'line {i+1}: {u!r} vs {v!r}'
            du, dv = decimal.Decimal(u), decimal.Decimal(v)
            where = f'line {i+1}: {u} vs {v}'
            if o.max_diff and abs(du - dv) <= decimal.Decimal(str(o.max_diff)):
                cand = (o.diff_label, None, where)
            elif scale_explained(du, dv):
                # Zero decimal places against a value with a real fractional part is not a
                # narrower result type, it is the fractional part being thrown away: int/int
                # division, or a decimal division that took its scale from an integer numerator.
                # TPC-DS asks for 0.67 and CedarDB answers 0 while Firebolt answers 1.
                lo, hi = sorted((du, dv), key=decimals)
                if decimals(lo) == 0 and hi != hi.to_integral_value():
                    cand = ('TRUNCATED', f'0dp vs {decimals(hi)}dp', where)
                else:
                    cand = ('SCALE', f'{decimals(du)}dp vs {decimals(dv)}dp', where)
            else:
                # Exactly one unit in the last place of the coarser value: the two are adjacent
                # at that scale, which is what truncating against rounding produces. 10714 vs
                # 10715, or 3.51 vs 3.52. A float discrepancy is far smaller than one ulp and a
                # wrong answer is far larger, so neither lands here.
                ulp = decimal.Decimal(1).scaleb(-min(decimals(du), decimals(dv)))
                if abs(du - dv) == ulp:
                    cand = ('ROUNDING', f'1 ulp at {min(decimals(du), decimals(dv))}dp', where)
                else:
                    s = sig_digits(du, dv)
                    cand = ('PRECISION' if s >= o.sig else 'DIFFER', f'{s}d', where)
            if RANK[cand[0]] > RANK[worst[0]]:
                worst = cand
            if worst[0] == 'DIFFER':
                return worst
    return worst

def mark_recorded(recorded, bench, stem, verdict, detail):
    """A listed query becomes RECORDED, labelled with its category from recorded-issues.txt."""
    hit = recorded.get((bench, stem))
    if not hit or verdict in ('SAME', 'IDENTICAL'):
        return verdict, detail
    return 'RECORDED', f'{hit[0]} {detail}'

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bench', nargs='*', default=['tpch', 'tpcds', 'job'])
    ap.add_argument('--sig', type=int, default=6,
                    help='significant digits below which a non-scale numeric diff is DIFFER')
    ap.add_argument('--only', default='', help='comma-separated systems to include')
    ap.add_argument('--max-diff', type=float, default=0.0,
                    help='treat numbers no further apart than this as agreeing, e.g. --max-diff 0.01')
    ap.add_argument('--recorded', default='recorded-issues.txt',
                    help="established causes, reported as RECORDED instead of DIFFER ('' to ignore)")
    ap.add_argument('--ignore-null-order', action='store_true',
                    help='do not call it a difference when a LIMIT kept different NULL-keyed rows')
    ap.add_argument('--verbose', action='store_true', help='show agreeing queries too')
    ap.add_argument('--root', default=pathlib.Path(__file__).resolve().parent)
    ap.add_argument('--out', default='query-results/comparison.txt',
                    help="write the list of non-agreeing queries here ('' to skip)")
    a = ap.parse_args()
    keep = set(filter(None, a.only.split(',')))
    # The verdict for an accepted difference states the threshold it was accepted under, so the
    # output can never be read without knowing the rule that produced it.
    a.diff_label = f'DIFF_BELOW_{a.max_diff:g}'
    RANK[a.diff_label] = DIFF_BELOW_RANK
    recorded = load_recorded(pathlib.Path(a.root) / a.recorded if a.recorded else '')

    exit_code = 0
    listing = []          # one line per query that did not agree, for --out
    for bench in a.bench:
        files = sorted((pathlib.Path(a.root) / 'query-results' / bench).glob('q*.txt'))
        if not files:
            continue
        print(f'== {bench}: {len(files)} queries with dumps')
        tally = collections.Counter()
        for path in files:
            got = parse(path)
            if keep:
                got = {k: v for k, v in got.items() if k in keep}
            if len(got) < 2:
                tally['single system'] += 1
                if a.verbose:
                    print(f'  {path.stem}  only {",".join(got) or "-"}')
                continue

            # Group by (status, canonicalised rows); systems in one group returned one answer.
            groups = collections.OrderedDict()
            for s, v in sorted(got.items()):
                rows = [canon_row(r) for r in v['rows']]
                groups.setdefault((v['status'], tuple(rows)), []).append(s)
            names = ['+'.join(g) for g in groups.values()]

            if len(groups) == 1:
                verbatim = len({tuple(v['rows']) for v in got.values()}) == 1
                verdict = 'IDENTICAL' if verbatim else 'SAME'
                tally[verdict] += 1
                if a.verbose:
                    print(f'  {path.stem}  {verdict:<16} all {len(got)} agree, '
                          f'{len(next(iter(groups))[1])} rows')
                continue

            statuses = {v['status'] for v in got.values()}
            if len(statuses) > 1:
                detail = ', '.join(f'{s}={v["status"]}' for s, v in sorted(got.items()))
                verdict, detail = mark_recorded(recorded, bench, path.stem, 'STATUS', detail)
                tally[verdict] += 1
                print(f'  {path.stem}  {verdict:<16} ' + detail)
                listing.append((bench, path.stem, verdict, detail))
                if verdict != 'RECORDED':
                    exit_code = 1
                continue

            # Largest group is the majority answer; describe every other group against it.
            order = sorted(groups.items(), key=lambda kv: -len(kv[1]))
            (_, base), base_sys = order[0]
            worst, lines = 'SAME', []
            base_raw = representative(base_sys, got)
            for (_, rows), syss in order[1:]:
                # Other group first, so the example reads in the same order as the label.
                v, detail, ex = compare_rows(representative(syss, got), base_raw,
                                             list(rows), list(base), a)
                if RANK[v] > RANK[worst]:
                    worst = v
                tag = v + (f'({detail})' if detail else '')
                lines.append(f'      {"+".join(syss)} vs {"+".join(base_sys)}: {tag}' +
                             (f'  {ex}' if ex else ''))
            worst, shown = mark_recorded(recorded, bench, path.stem, worst,
                                      f'{len(groups)} distinct answers: {", ".join(names)}')
            tally[worst] += 1
            if worst != 'SAME':
                listing.append((bench, path.stem, worst, shown))
            if worst != 'SAME' or a.verbose:
                print(f'  {path.stem}  {worst:<16} {shown}')
                print('\n'.join(lines))
            if worst == 'DIFFER':
                exit_code = 1
        print('   ' + ', '.join(f'{k} {n}' for k, n in sorted(tally.items())) + '\n')

    if a.out:
        out = pathlib.Path(a.root) / a.out
        out.parent.mkdir(parents=True, exist_ok=True)
        with out.open('w') as f:
            f.write(f'# queries that did not agree, {datetime.datetime.now(datetime.timezone.utc):%Y-%m-%dT%H:%M:%SZ}\n')
            f.write(f'# systems: {", ".join(sorted(keep)) if keep else "all in the dumps"}\n')
            f.write(f'# rules: sig={a.sig}, max_diff={a.max_diff}, '
                    f'ignore_null_order={a.ignore_null_order}\n')
            for b, q, v, detail in listing:
                f.write(f'{b:6} {q:6} {v:<16} {detail}\n')
        print(f'wrote {a.out}: {len(listing)} queries that did not agree')
    return exit_code

if __name__ == '__main__':
    sys.exit(main())
