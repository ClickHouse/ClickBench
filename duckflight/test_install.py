"""Check compiler selection without invoking a compiler or downloading sources."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class InstallTests(unittest.TestCase):
    def test_pinned_toolchain_precedes_existing_cargo_and_preserves_mbx(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            implementation = root / "runner"
            (implementation / "native-client").mkdir(parents=True)
            (implementation / ".tools").mkdir()
            shutil.copy2(
                Path(__file__).with_name("native-client") / "build.sh",
                implementation / "native-client/build.sh",
            )
            source = root / "source"
            (source / "target/release").mkdir(parents=True)
            fake_binary = source / "target/release/flight_sql_client"
            fake_binary.write_text("test artifact\n")
            fake_bin = root / "bin"
            pinned_bin = root / "pinned"
            fake_bin.mkdir()
            pinned_bin.mkdir()

            def executable(path, script):
                path.write_text("#!/bin/bash\nset -eu\n" + script)
                path.chmod(0o755)

            executable(fake_bin / "uv", 'printf "%s\\n" "$TEST_SOURCE"\n')
            executable(
                fake_bin / "rustup",
                'if [ "$1" = which ]; then printf "%s\\n" "$TEST_PINNED/cargo"; fi\n',
            )
            for name in ["cargo", "rustc"]:
                executable(
                    fake_bin / name, 'echo "wrong toolchain selected" >&2; exit 77\n'
                )
            executable(
                fake_bin / "mbx", 'echo used > "$TEST_MBX_LOG"\nexec cargo "$@"\n'
            )
            executable(
                pinned_bin / "cargo",
                'if [ "$1" = --version ]; then echo "cargo 1.99.0"; fi\n',
            )
            executable(pinned_bin / "rustc", 'echo "rustc 1.99.0 (test compiler)"\n')
            env = {
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ['PATH']}",
                "TEST_SOURCE": str(source),
                "TEST_PINNED": str(pinned_bin),
                "TEST_MBX_LOG": str(root / "mbx.log"),
                "CARGO_TARGET_DIR": str(source / "target"),
            }
            for key in [
                "RUSTC",
                "RUSTC_WRAPPER",
                "RUSTC_WORKSPACE_WRAPPER",
                "CARGO_BUILD_RUSTC_WRAPPER",
                "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER",
            ]:
                env.pop(key, None)
            subprocess.run(
                ["bash", str(implementation / "native-client/build.sh")],
                env=env,
                check=True,
                timeout=30,
            )
            self.assertEqual(
                (implementation / ".tools/flight_sql_client").read_text(),
                fake_binary.read_text(),
            )
            self.assertEqual((root / "mbx.log").read_text(), "used\n")
            self.assertIn(
                "rustc 1.99.0",
                (implementation / ".tools/rust-toolchain.txt").read_text(),
            )


if __name__ == "__main__":
    unittest.main()
