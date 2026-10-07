#!/usr/bin/env python3
"""Load all Parquet rows as hashes without rounding signed 64-bit IDs."""
import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import datetime
import json
import os
from pathlib import Path
import re
import sys
import time

import pyarrow.parquet as pq
import redis

EXPECTED_ROWS = 99_997_497


def column_types():
    ddl = Path(__file__).with_name('create.sql').read_text()
    return [(name.lower(), typ.lower()) for name, typ in re.findall(
        r'^\s+(\w+)\s+(bigint|smallint|integer|varchar|date|timestamp\(3\))', ddl, re.M | re.I)]


def encode(value, typ):
    if value is None:
        raise ValueError('The ClickBench dataset must not contain NULL')
    if typ == 'timestamp(3)':
        if isinstance(value, datetime.datetime):
            value = value.replace(tzinfo=datetime.timezone.utc).timestamp()
        return str(int(value) * 1000)  # Parquet timestamps are epoch seconds
    if typ == 'date':
        if isinstance(value, int):
            value = datetime.date(1970, 1, 1) + datetime.timedelta(days=value)
        return str(value)
    if isinstance(value, bytes):
        return value.decode('utf-8')
    return str(value)


def client():
    # Credentials are read from a private file, never from a tracked file or argv.
    config = os.environ.get('REDIS_CONNECTION_FILE')
    if config:
        options = json.loads(Path(config).read_text())
        cls = redis.RedisCluster if os.environ.get('REDIS_CLUSTER') == 'true' else redis.Redis
        return cls(**options, socket_connect_timeout=10, socket_timeout=1200)
    return redis.Redis(host='127.0.0.1', port=16379,
                       socket_connect_timeout=10, socket_timeout=1200)


def load_group(task):
    path, group, offset, resume = task
    r = client()
    types = column_types()
    source = pq.ParquetFile(path)
    size = source.metadata.row_group(group).num_rows
    # A row group is written in physical order with successful pipelines. If its
    # last row survived an interruption, its earlier rows have already committed.
    # Partial groups are rewritten idempotently; final global counts still apply.
    if resume and r.exists(f'hits:{offset + size - 1}'):
        r.close()
        return size
    count = 0
    for batch in source.iter_batches(batch_size=1000, row_groups=[group]):
        columns = {name.lower(): values for name, values in batch.to_pydict().items()}
        pipe = r.pipeline(transaction=False)
        for position in range(batch.num_rows):
            row = {name: encode(columns[name][position], typ) for name, typ in types}
            pipe.hset(f'hits:{offset + count}', mapping=row)
            count += 1
        pipe.execute()
    r.close()
    return count


def load(path, expected_rows, limit=None, workers=1, resume=False):
    r = client()
    types = column_types()
    source = pq.ParquetFile(path)
    total = source.metadata.num_rows
    if limit is None and total != expected_rows:
        raise ValueError(f'Parquet row count {total} != {expected_rows}')
    count = 0
    if workers > 1:
        if limit is not None:
            raise ValueError('Parallel loading requires the full dataset')
        tasks = []
        offset = 0
        for group in range(source.num_row_groups):
            tasks.append((path, group, offset, resume))
            offset += source.metadata.row_group(group).num_rows
        with ProcessPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(load_group, task) for task in tasks]
            for future in as_completed(futures):
                count += future.result()
                print(f'Loaded {count:,} rows', file=sys.stderr, flush=True)
    for batch in (() if workers > 1 else source.iter_batches(batch_size=1000)):
        columns = {name.lower(): values for name, values in batch.to_pydict().items()}
        pipe = r.pipeline(transaction=False)
        for position in range(batch.num_rows):
            if limit is not None and count >= limit:
                break
            # WatchID is not unique. The physical row ordinal preserves duplicates.
            row = {name: encode(columns[name][position], typ) for name, typ in types}
            pipe.hset(f'hits:{count}', mapping=row)
            count += 1
        pipe.execute()  # Errors such as OOM abort, rather than timing a partial table.
        if count % 1_000_000 == 0:
            print(f'Loaded {count:,} rows', file=sys.stderr, flush=True)
        if limit is not None and count >= limit:
            break
    target = min(limit, total) if limit is not None else expected_rows
    assert count == target, (count, target)
    deadline = time.monotonic() + 3600
    while True:
        raw = r.execute_command('FT.INFO', 'hits')
        info = dict(zip(raw[::2], raw[1::2]))
        if int(info.get(b'hash_indexing_failures', 0)):
            raise RuntimeError('Search indexing failures detected')
        if not int(info[b'indexing']) and int(info[b'num_docs']) == target:
            break
        if time.monotonic() > deadline:
            raise RuntimeError(f'Index incomplete after load: {info[b"num_docs"]} / {target}')
        time.sleep(1)
    raw_errors = info.get(b'Index Errors', [])
    errors = dict(zip(raw_errors[::2], raw_errors[1::2]))
    if int(errors.get(b'indexing failures', 0)):
        raise RuntimeError('Search indexing failures detected')
    print(f'Verified {count:,} indexed rows', file=sys.stderr)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('parquet')
    parser.add_argument('--expected-rows', type=int, default=EXPECTED_ROWS)
    parser.add_argument('--limit', type=int, help='Smoke test only; never publish as ClickBench')
    parser.add_argument('--workers', type=int, default=1)
    parser.add_argument('--resume', action='store_true', help='Resume an interrupted ordinal-key load of the same file; do not publish a fresh-load timing')
    args = parser.parse_args()
    if args.workers < 1:
        parser.error('--workers must be positive')
    if args.resume and (args.workers < 2 or args.limit is not None):
        parser.error('--resume requires parallel full-dataset loading')
    load(args.parquet, args.expected_rows, args.limit, args.workers, args.resume)
