"""Prepare the pinned Apache Arrow client with execution-through-fetch timing."""

from __future__ import annotations

import hashlib
import shutil
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
TOOLS = ROOT.parent / ".tools" / "arrow-flight"
VERSION = "60.0.0"
CHECKSUM = "fbc77d8656483656cbf966e04b62f193f74111ff7d9cc15f58a549314a3b061e"

TOOLS.mkdir(parents=True, exist_ok=True)
archive = TOOLS / f"arrow-flight-{VERSION}.crate"
if not archive.exists():
    url = f"https://static.crates.io/crates/arrow-flight/arrow-flight-{VERSION}.crate"
    with urllib.request.urlopen(url, timeout=120) as response:
        archive.write_bytes(response.read())
if hashlib.sha256(archive.read_bytes()).hexdigest() != CHECKSUM:
    raise RuntimeError("Apache Arrow source checksum mismatch")
with tarfile.open(archive) as package:
    package.extractall(TOOLS, filter="data")
source = TOOLS / f"arrow-flight-{VERSION}"
client = source / "src/bin/flight_sql_client.rs"
text = client.read_text()
changes = [
    (
        "use std::{sync::Arc, time::Duration};",
        "use std::{sync::Arc, time::{Duration, Instant}};",
    ),
    (
        "struct Args {",
        (
            "struct Args {\n"
            "    /// Emit complete CSV and execution-through-fetch seconds.\n"
            "    #[clap(long)]\n"
            "    benchmark: bool,\n"
        ),
    ),
    (
        "    let flight_info = match args.cmd {",
        "    let started = Instant::now();\n    let flight_info = match args.cmd {",
    ),
    (
        (
            '    let res = pretty_format_batches(batches.as_slice()).context("format results")?;\n'
            '    println!("{res}");'
        ),
        (
            "    let seconds = started.elapsed().as_secs_f64();\n"
            "    if args.benchmark {\n"
            "        let mut writer = arrow_csv::WriterBuilder::new()\n"
            '            .with_null("\\\\N".to_string())\n'
            "            .build(std::io::stdout().lock());\n"
            "        for batch in &batches {\n"
            '            writer.write(batch).context("write CSV")?;\n'
            "        }\n"
            '        eprintln!("{seconds:.9}");\n'
            "    } else {\n"
            '        let res = pretty_format_batches(batches.as_slice()).context("format results")?;\n'
            '        println!("{res}");\n'
            "    }"
        ),
    ),
]
for old, new in changes:
    if text.count(old) != 1:
        raise RuntimeError("published Arrow CLI no longer matches measurement patch")
    text = text.replace(old, new)
client.write_text(text)
manifest = source / "Cargo.toml"
manifest.write_text(
    manifest.read_text()
    + '\n[workspace]\n\n[dependencies.arrow-csv]\nversion = "=60.0.0"\n'
)
shutil.copyfile(ROOT / "Cargo.lock", source / "Cargo.lock")
print(source)
