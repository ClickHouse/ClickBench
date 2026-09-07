#!/usr/bin/env python3
"""Record one query's result rows into query-results/<benchmark>/q<NNN>.txt.

Every system appends to the SAME file, one block each, so comparing engines is reading one file.

Called by each runner with the raw client output on stdin:

    ... | emit-result.py --system clickhouse --bench tpch --query 1 \
                        --status ok --version 26.7.5.10 --null-token '\\N'

APPEND IS IDEMPOTENT. A re-run replaces that system's block.

WHAT IS NORMALISED, and only this:
  * NULL -> the single token <NULL>. Each client spells it differently.
  * Trailing NUL bytes and trailing spaces are stripped from every field.
  * With --tsv-escaped, the two-character sequence \\0 becomes a real NUL before that strip.

WHAT IS NOT normalised: numbers are written exactly as the engine printed them. 
Row order is likewise left as returned.
"""
import argparse, datetime, os, pathlib, sys

HDR = '=== '

def canonical(line, null_token, tsv_escaped):
    out = []
    for field in line.split('\t'):
        if field == null_token:
            out.append('<NULL>')
            continue
        if tsv_escaped:
            field = field.replace('\\0', '\0')
        out.append(field.rstrip('\0 '))
    return '\t'.join(out)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--system', required=True)
    ap.add_argument('--bench', required=True)
    ap.add_argument('--query', required=True, type=int, help='1-based position in queries/<bench>.sql')
    ap.add_argument('--status', required=True, help='ok | empty | timeout | oom | unsupported | error')
    ap.add_argument('--version', default='')
    ap.add_argument('--message', default='', help='engine message, for a non-ok status')
    ap.add_argument('--null-token', default='\\N')
    ap.add_argument('--tsv-escaped', action='store_true',
                    help='client escapes its output (ClickHouse, mysql): unescape \\0 padding')
    ap.add_argument('--root', default=os.path.dirname(os.path.abspath(__file__)))
    a = ap.parse_args()

    raw = sys.stdin.read()
    rows = [canonical(l, a.null_token, a.tsv_escaped) for l in raw.split('\n') if l != '']
    status = a.status
    if status == 'ok' and not rows:
        status = 'empty'          # distinguishable from a failure, and worth seeing

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    block = [f'{HDR}{a.system} | status={status} | rows={len(rows)} | {stamp} | {a.version}']
    if a.message:
        block += ['# ' + m for m in a.message.strip().split('\n')[:3]]
    block += rows

    path = pathlib.Path(a.root) / 'query-results' / a.bench / f'q{a.query:03d}.txt'
    path.parent.mkdir(parents=True, exist_ok=True)

    kept, skipping = [], False
    if path.exists():
        for line in path.read_text().split('\n'):
            if line.startswith(HDR):
                skipping = line[len(HDR):].split(' |')[0].strip() == a.system
            if not skipping and line != '':
                kept.append(line)
    path.write_text('\n'.join(kept + block) + '\n')
    print(f'{a.bench} q{a.query}: {a.system} {status}, {len(rows)} rows', file=sys.stderr)

if __name__ == '__main__':
    main()
