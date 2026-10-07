#!/usr/bin/env python3
"""Run one ClickBench query, retaining three attempts and existing measurements."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import runpy
import subprocess
from query import execute

parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=('default', 'cluster'), required=True)
parser.add_argument('--query', type=int, choices=range(1, 44), required=True)
a = parser.parse_args()
queries = Path('queries.sql').read_text().splitlines()
assert len(queries) == 43
r = Path(os.environ.get('RESULT_DIR', 'cloud-results-' + a.mode))
r.mkdir(exist_ok=True)
samples = [json.loads(line) for line in (r / 'samples.jsonl').read_text().splitlines()] if (r / 'samples.jsonl').exists() else []
assert not any(s['query'] == a.query and s['mode'] == a.mode for s in samples), 'Query already has attempts; preserve them'
os.environ['TRINO_CATALOG'] = 'redis_' + a.mode
subprocess.run(['docker', 'restart', 'clickbench-cloud-trino'], check=True, stdout=subprocess.DEVNULL)
subprocess.run(['sudo', 'sh', '-c', 'sync; echo 3 > /proc/sys/vm/drop_caches'], check=True)
runpy.run_path('run-cloud.py')['ready']()
for attempt in range(1, 4):
    output = r / f'q{a.query:02d}-{a.mode}-{attempt}.csv'
    try:
        with output.open('w', newline='') as f:
            seconds = execute(queries[a.query - 1], f)
        error = None
    except Exception as e:
        seconds = None
        error = str(e)
    s = dict(query=a.query, mode=a.mode, try_=attempt, seconds=seconds, error=error,
             output_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    s['try'] = s.pop('try_')
    samples.append(s)
    with (r / 'samples.jsonl').open('a') as f:
        f.write(json.dumps(s) + '\n')
    print(json.dumps(s), flush=True)
(r / f'q{a.query:02d}-{a.mode}-complete.json').write_text(json.dumps(dict(query=a.query, mode=a.mode, tries=3)) + '\n')
indexed = {(s['query'], s['try']): s for s in samples if s['mode'] == a.mode}
assert len(indexed) == len(samples), 'Duplicate attempts or mixed modes'
timings = [[indexed[q, t]['seconds'] if (q, t) in indexed else None for t in range(1, 4)] for q in range(1, 44)]
(r / (a.mode + '-timings.json')).write_text(json.dumps(timings, indent=2) + '\n')
if len(indexed) == 129:
    (r / (a.mode + '-benchmark.log')).write_text(''.join(json.dumps(row) + ',\n' for row in timings))
    cancelled = [{'query': s['query'], 'try': s['try'], 'error': s['error']} for s in samples if s.get('cancelled')]
    (r / 'complete.json').write_text(json.dumps(dict(queries=43, tries=3, tags=['no-cold'], mode=a.mode,
        redis_restarted=False, cancelled_attempts=cancelled), indent=2) + '\n')
