#!/usr/bin/env python3
"""Trino HTTP client: consume every result page; wall time on stderr."""
import csv
import json
import os
import sys
import time
import urllib.request


def execute(sql, output=sys.stdout):
    server = os.environ.get('TRINO_SERVER', 'http://127.0.0.1:18080').rstrip('/')
    timeout = int(os.environ.get('QUERY_TIMEOUT_SECONDS', '1200'))
    headers = {'X-Trino-User': 'clickbench', 'X-Trino-Catalog': os.environ.get('TRINO_CATALOG', 'redisearch'),
               'X-Trino-Schema': 'default', 'X-Trino-Time-Zone': 'UTC',
               'X-Trino-Session': f'query_max_run_time={timeout}s'}
    request = urllib.request.Request(server + '/v1/statement', sql.strip().removesuffix(';').encode(), headers)
    writer = csv.writer(output)
    started = time.perf_counter()
    try:
        while True:
            with urllib.request.urlopen(request, timeout=timeout + 30) as response:
                page = json.load(response)
            if 'error' in page:
                raise RuntimeError(page['error']['message'])
            writer.writerows(page.get('data', []))
            if 'nextUri' not in page:
                break
            request = urllib.request.Request(page['nextUri'], headers=headers)
        output.flush()
    finally:
        elapsed = time.perf_counter() - started
    return elapsed


if __name__ == '__main__':
    try:
        elapsed = execute(sys.stdin.read())
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    print(f'{elapsed:.6f}', file=sys.stderr)
