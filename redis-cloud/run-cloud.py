#!/usr/bin/env python3
"""Compare APIs, preserving all 43 queries and three end-to-end tries each."""
import csv
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
from query import execute


def ready():
    deadline=time.monotonic()+300
    while time.monotonic()<deadline:
        try:
            with urllib.request.urlopen('http://127.0.0.1:18080/v1/info',timeout=5) as r:
                if not json.load(r)['starting']: return
        except Exception:
            pass
        time.sleep(2)
    raise RuntimeError('Trino failed to restart')


def run():
    queries=Path('queries.sql').read_text().splitlines()
    assert len(queries)==43
    target=Path(os.environ.get('RESULT_DIR','cloud-results'))
    target.mkdir(exist_ok=True)
    # Alternate which API goes first for each query, to balance server cache/order effects.
    results={m:[] for m in ('default','cluster')}
    samples=[]
    for i,sql in enumerate(queries,1):
        modes=('default','cluster') if i%2 else ('cluster','default')
        for mode in modes:
            os.environ['TRINO_CATALOG']=f'redis_{mode}'
            subprocess.run(['docker','restart','clickbench-cloud-trino'],check=True,stdout=subprocess.DEVNULL)
            subprocess.run(['sudo','sh','-c','sync; echo 3 > /proc/sys/vm/drop_caches'],check=True)
            ready()
            tries=[]
            for attempt in range(1,4):
                output=target/f'q{i:02d}-{mode}-{attempt}.csv'
                try:
                    with output.open('w') as f: elapsed=execute(sql,f)
                    error=None
                except Exception as e:
                    elapsed=None; error=str(e)
                tries.append(elapsed)
                sample={'query':i,'mode':mode,'try':attempt,'seconds':elapsed,'error':error,
                        'output_sha256':hashlib.sha256(output.read_bytes()).hexdigest()}
                samples.append(sample)
                with (target/'samples.jsonl').open('a') as f: f.write(json.dumps(sample)+'\n')
                print(json.dumps(sample),flush=True)
            results[mode].append(tries)
            (target/f'{mode}-timings.json').write_text(json.dumps(results[mode],indent=2)+'\n')
    for mode in results:
        with (target/f'{mode}-benchmark.log').open('w') as f:
            for row in results[mode]: f.write(json.dumps(row)+',\n')
    # Redis Cloud cannot be restarted between queries: published results MUST use no-cold.
    (target/'complete.json').write_text(json.dumps({'queries':43,'tries':3,'tags':['no-cold'],
        'api_order':'alternates per query','redis_restarted':False},indent=2)+'\n')


if __name__=='__main__':
    run()
