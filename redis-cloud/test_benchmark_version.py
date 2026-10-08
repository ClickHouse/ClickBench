import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from benchmark_version import MANIFEST, digest, record, require_current_run, verify

REVISION = 'a' * 40


class VersionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plugin = Path(self.temp.name) / 'plugin'
        self.plugin.mkdir()
        self.jar = self.plugin / 'redis-sql-trino-0.4.2-SNAPSHOT.jar'
        self.jar.write_bytes(b'connector test fixture')
        record(self.plugin, REVISION, 'sha256:fixture')

    def test_matching_latest_build(self):
        with patch('benchmark_version.latest_revision', return_value=REVISION):
            self.assertEqual(verify(self.plugin, REVISION)['connector_revision'], REVISION)

    def test_stale_revision_rejected(self):
        with patch('benchmark_version.latest_revision', return_value='b' * 40):
            with self.assertRaisesRegex(RuntimeError, 'behind master'):
                verify(self.plugin, REVISION)
        with self.assertRaisesRegex(RuntimeError, 'differs from benchmark pin'):
            verify(self.plugin, 'b' * 40, latest=False)

    def test_tampered_missing_and_extra_jars_rejected(self):
        for action in ['tamper', 'missing', 'extra']:
            with self.subTest(action=action):
                self.jar.write_bytes(b'connector test fixture')
                record(self.plugin, REVISION, 'sha256:fixture')
                if action == 'tamper':
                    self.jar.write_bytes(b'changed')
                elif action == 'missing':
                    self.jar.unlink()
                else:
                    (self.plugin / 'stale-dependency.jar').write_bytes(b'old')
                with self.assertRaisesRegex(RuntimeError, 'JARs differ'):
                    verify(self.plugin, REVISION, latest=False)

    def test_stale_container_rejected(self):
        info = dict(Config=dict(Labels={'clickbench.connector-revision': REVISION,
                    'clickbench.plugin-manifest-sha256': 'old'}), Mounts=[])
        with patch('benchmark_version.subprocess.check_output', return_value=json.dumps([info])):
            with self.assertRaisesRegex(RuntimeError, 'older connector build'):
                verify(self.plugin, REVISION, latest=False, container='trino')
        info['Config']['Labels']['clickbench.plugin-manifest-sha256'] = digest(self.plugin / MANIFEST)
        info['Mounts'] = [dict(Source=str(self.plugin), Destination='/usr/lib/trino/plugin/redisearch', RW=False)]
        with patch('benchmark_version.subprocess.check_output', return_value=json.dumps([info])) as inspect:
            verify(self.plugin, REVISION, latest=False, container='trino')
            info['Mounts'][0]['RW'] = True
            inspect.return_value = json.dumps([info])
            with self.assertRaisesRegex(RuntimeError, 'read-only'):
                verify(self.plugin, REVISION, latest=False, container='trino')

    def test_old_results_preserved(self):
        result = Path(self.temp.name) / 'results'
        result.mkdir()
        (result / 'samples.jsonl').write_text('old samples\n')
        manifest = json.loads((self.plugin / MANIFEST).read_text())
        with patch('benchmark_version.verify', return_value=manifest):
            with self.assertRaisesRegex(RuntimeError, 'lack build provenance'):
                require_current_run(result)
        self.assertEqual((result / 'samples.jsonl').read_text(), 'old samples\n')
        self.assertFalse((result / MANIFEST).exists())


if __name__ == '__main__':
    unittest.main()
