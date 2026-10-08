#!/usr/bin/env python3
"""Fail closed on stale/mismatched benchmark connector artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

REMOTE = 'https://github.com/redis-field-engineering/redis-sql-trino.git'
MANIFEST = 'connector-build.json'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def jars(plugin):
    return {str(path.relative_to(plugin)): digest(path) for path in sorted(plugin.rglob('*.jar'))}


def latest_revision():
    output = subprocess.check_output(['git', 'ls-remote', REMOTE, 'refs/heads/master'], text=True)
    lines = output.splitlines()
    if len(lines) != 1 or not re.fullmatch(r'[0-9a-f]{40}\s+refs/heads/master', lines[0]):
        raise RuntimeError('Cannot establish latest master revision')
    return lines[0].split()[0]


def record(plugin, revision, image_id):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise RuntimeError('Require an immutable full connector revision')
    files = jars(plugin)
    if not any(Path(name).name.startswith('redis-sql-trino-') and not Path(name).name.endswith(('-sources.jar', '-javadoc.jar', '-tests.jar')) for name in files):
        raise RuntimeError('Connector JAR missing from plugin')
    manifest = dict(connector_revision=revision, build_image_id=image_id, jar_sha256=files)
    (plugin / MANIFEST).write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def verify(plugin, expected, latest=True, container=None):
    manifest_path = plugin / MANIFEST
    manifest = json.loads(manifest_path.read_text())
    if manifest['connector_revision'] != expected:
        raise RuntimeError('Plugin revision differs from benchmark pin; rebuild')
    if latest and latest_revision() != expected:
        raise RuntimeError('Benchmark pin is behind master; update versions.env and rebuild')
    if not manifest.get('jar_sha256') or manifest['jar_sha256'] != jars(plugin):
        raise RuntimeError('Plugin JARs differ from recorded build; rebuild')
    if container:
        info = json.loads(subprocess.check_output(['docker', 'inspect', container], text=True))[0]
        labels = info['Config'].get('Labels') or {}
        if labels.get('clickbench.connector-revision') != expected or labels.get('clickbench.plugin-manifest-sha256') != digest(manifest_path):
            raise RuntimeError('Running Trino has an older connector build; recreate container')
        mounts = [m for m in info.get('Mounts', []) if m.get('Destination') == '/usr/lib/trino/plugin/redisearch']
        if len(mounts) != 1 or Path(mounts[0]['Source']).resolve() != plugin.resolve() or mounts[0].get('RW', True):
            raise RuntimeError('Running Trino does not mount the verified plugin read-only')
    return manifest


def require_current_run(target):
    root = Path(__file__).resolve().parent
    values = dict(line.split('=', 1) for line in (root / 'versions.env').read_text().splitlines() if '=' in line)
    plugin = Path(os.environ.get('PLUGIN_DIR', str(root / 'plugin'))).resolve()
    manifest = verify(plugin, values['CONNECTOR_REVISION'], container='clickbench-cloud-trino')
    path = target / MANIFEST
    if path.exists() and json.loads(path.read_text()) != manifest:
        raise RuntimeError('Result directory contains another connector build; use a fresh directory')
    if not path.exists() and ((target / 'samples.jsonl').exists() or (target / 'complete.json').exists()):
        raise RuntimeError('Existing results lack build provenance; preserve them and use a fresh directory')
    target.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['record', 'verify'])
    parser.add_argument('--plugin', type=Path, required=True)
    parser.add_argument('--revision', required=True)
    parser.add_argument('--image-id')
    args = parser.parse_args()
    if args.action == 'record':
        if not args.image_id:
            parser.error('record requires --image-id')
        record(args.plugin, args.revision, args.image_id)
    else:
        verify(args.plugin, args.revision)
    print(args.revision)


if __name__ == '__main__':
    main()
