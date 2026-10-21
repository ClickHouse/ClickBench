"""Exercise independent entry hooks, regional defaults and server isolation."""

import csv
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import validate_native

ROOT = Path(__file__).resolve().parent
ENTRIES = {
    "duckflight": "native",
    "duckflight-datalake": "datalake",
    "duckflight-datalake-partitioned": "datalake-partitioned",
}


class EntryTests(unittest.TestCase):
    def test_validator_honors_alternate_state_and_explicit_override(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            baseline = root / "baseline.json"
            baseline.write_text(
                json.dumps({"queries": [{"flight_matches": True}] * 43})
            )
            for explicit in [False, True]:
                state = root / ("explicit" if explicit else "environment")
                arguments = [
                    "validate-native",
                    "--baseline",
                    str(baseline),
                    "--output",
                    str(root / "validation.json"),
                ]
                if explicit:
                    arguments.extend(["--state", str(state)])
                with (
                    self.subTest(explicit=explicit),
                    patch.dict(
                        os.environ,
                        {"DUCKFLIGHT_BENCH_STATE": str(root / "environment")},
                    ),
                    patch("sys.argv", arguments),
                    patch.object(
                        validate_native.harness,
                        "start",
                        side_effect=RuntimeError("state probe"),
                    ) as start,
                    self.assertRaisesRegex(RuntimeError, "state probe"),
                ):
                    validate_native.main()
                start.assert_called_once_with(state.resolve())

    def test_independent_hooks_select_entry_state_and_regional_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "lib").mkdir()
            shutil.copy2(
                ROOT.parent / "lib/dataset-bucket.sh", root / "lib/dataset-bucket.sh"
            )
            for entry in ENTRIES:
                shutil.copytree(
                    ROOT.parent / entry,
                    root / entry,
                    ignore=shutil.ignore_patterns(
                        ".tools", ".state", ".venv", "__pycache__", "results"
                    ),
                )
            tools = root / "tools"
            tools.mkdir()
            uv = tools / "uv"
            uv.write_text("#!/bin/bash\nexec env\n")
            uv.chmod(0o755)
            for entry, mode in ENTRIES.items():
                for bucket, region in [
                    ("clickhouse-public-datasets", "eu-central-1"),
                    ("clickhouse-public-datasets--us-east-1", "us-east-1"),
                ]:
                    for hook in ["load", "start"]:
                        with self.subTest(entry=entry, bucket=bucket, hook=hook):
                            env = {
                                key: value
                                for key, value in os.environ.items()
                                if not key.startswith("DUCKFLIGHT_BENCH_")
                            }
                            env.update(
                                PATH=f"{tools}:{env['PATH']}",
                                CLICKBENCH_DATASET_BUCKET=bucket,
                            )
                            output = subprocess.check_output(
                                [str(root / entry / hook)], env=env, text=True
                            )
                            actual = dict(
                                line.split("=", 1)
                                for line in output.splitlines()
                                if "=" in line
                            )
                            self.assertEqual(actual["DUCKFLIGHT_BENCH_STORAGE"], mode)
                            self.assertEqual(
                                actual["DUCKFLIGHT_BENCH_ENTRY"], str(root / entry)
                            )
                            self.assertEqual(
                                actual["DUCKFLIGHT_BENCH_STATE"],
                                str(root / entry / ".state"),
                            )
                            if mode != "native":
                                self.assertEqual(
                                    actual["DUCKFLIGHT_BENCH_S3_REGION"], region
                                )
                                self.assertIn(
                                    bucket, actual["DUCKFLIGHT_BENCH_PARQUET_SOURCE"]
                                )
                                env.update(
                                    DUCKFLIGHT_BENCH_PARQUET_SOURCE="https://example.test/custom.parquet",
                                    DUCKFLIGHT_BENCH_S3_REGION="custom-region",
                                )
                                overridden = subprocess.check_output(
                                    [str(root / entry / hook)], env=env, text=True
                                )
                                self.assertIn(
                                    "DUCKFLIGHT_BENCH_PARQUET_SOURCE=https://example.test/custom.parquet",
                                    overridden,
                                )
                                self.assertIn(
                                    "DUCKFLIGHT_BENCH_S3_REGION=custom-region",
                                    overridden,
                                )

    def test_all_three_entries_run_isolated_real_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            states = []
            try:
                for number, entry in enumerate(ENTRIES):
                    state = Path(directory) / entry
                    state.mkdir()
                    env = {
                        key: value
                        for key, value in os.environ.items()
                        if not key.startswith("DUCKFLIGHT_BENCH_")
                    }
                    env.update(
                        DUCKFLIGHT_BENCH_STATE=str(state),
                        CLICKBENCH_DATASET_BUCKET="clickhouse-public-datasets--us-east-1",
                    )
                    # Provision each mode through its installer, including httpfs
                    # on a fresh host. Reuse the already-built Rust query client.
                    subprocess.run(
                        [str(ROOT.parent / entry / "install")],
                        env={**env, "DUCKFLIGHT_BENCH_CLIENT": "python"},
                        check=True,
                        capture_output=True,
                        timeout=180,
                    )
                    states.append((entry, state, env))
                    subprocess.run(
                        [str(ROOT.parent / entry / "start")],
                        env=env,
                        check=True,
                        timeout=150,
                    )
                    subprocess.run(
                        [str(ROOT.parent / entry / "query")],
                        input=f"create table marker as select {number} as value;",
                        env=env,
                        text=True,
                        capture_output=True,
                        check=True,
                        timeout=150,
                    )
                addresses = set()
                for number, (entry, state, env) in enumerate(states):
                    addresses.add(
                        json.loads((state / "server.json").read_text())["address"]
                    )
                    result = subprocess.run(
                        [str(ROOT.parent / entry / "query")],
                        input="select * from marker;",
                        env=env,
                        text=True,
                        capture_output=True,
                        check=True,
                        timeout=150,
                    )
                    self.assertEqual(
                        list(csv.reader(io.StringIO(result.stdout))),
                        [["value"], [str(number)]],
                    )
                self.assertEqual(len(addresses), 3)
            finally:
                failures = []
                for entry, _, env in reversed(states):
                    result = subprocess.run(
                        [str(ROOT.parent / entry / "stop")],
                        env=env,
                        check=False,
                        capture_output=True,
                        text=True,
                        timeout=150,
                    )
                    if result.returncode:
                        failures.append(f"{entry}: {result.stderr}")
                if failures:
                    self.fail("\n".join(failures))


if __name__ == "__main__":
    unittest.main()
