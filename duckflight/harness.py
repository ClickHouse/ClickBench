"""ClickBench hooks for the released DuckFlight extension over Flight SQL."""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import platform
import secrets
import signal
import subprocess
import sys
import threading
import time
import urllib.request
import zipfile
from contextlib import contextmanager
from pathlib import Path

import duckdb
import pyarrow
from adbc_driver_flightsql import dbapi
from adbc_driver_manager import AdbcStatement

ROOT = Path(__file__).resolve().parent
RELEASE = "v0.1.12"
DUCKDB_VERSION = "1.5.6"
CHECKSUMS = {
    "linux_amd64": "c274636b29671a5453c12d169003da8dc21c0b01f64f62074406acdfdc9f3eaf",
    "linux_arm64": "8bfe1c78195498fe36166e0b434d0639cd02d19fd02455228ff8481a18947ea7",
    "osx_amd64": "696f332d663d2b6c8338cb4b5218b145912a8aec29889cd41dda0c915c88a4bb",
    "osx_arm64": "5a6b7b11dc2a862e8b213a5ce3c9627997b399495b7ec7fa973a88b8f7678bef",
}
EXPECTED_ROWS = 99_997_497
CLI_ASSETS = {
    "linux_amd64": (
        "linux-amd64",
        "6e89deac1ebbc36eed0291caf8b567b030c7b86ac35998f71854e22b3c5d5e2f",
    ),
    "linux_arm64": (
        "linux-arm64",
        "c544e92c9b7c31fc53c2139802cabd8e2d1b2b3e3f933117f31611239c1402db",
    ),
    "osx_amd64": (
        "osx-universal",
        "80a80c68736bd7dea53e8b02447e9759db0c8596ea156476ba396c44f54c5810",
    ),
    "osx_arm64": (
        "osx-universal",
        "80a80c68736bd7dea53e8b02447e9759db0c8596ea156476ba396c44f54c5810",
    ),
}


def sql_string(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def install(state: Path) -> None:
    os_name = {"Linux": "linux", "Darwin": "osx"}[platform.system()]
    arch = {"x86_64": "amd64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine()]
    target = f"{os_name}_{arch}"
    asset = f"duckflight-v{DUCKDB_VERSION}-{target}.duckdb_extension"
    path = state / "duckflight.duckdb_extension"
    if (
        not path.exists()
        or hashlib.sha256(path.read_bytes()).hexdigest() != CHECKSUMS[target]
    ):
        url = f"https://github.com/sidequery/duckflight-extension/releases/download/{RELEASE}/{asset}"
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != CHECKSUMS[target]:
            raise RuntimeError("extension checksum mismatch")
        path.write_bytes(data)
    cli_target, checksum = CLI_ASSETS[target]
    archive = state / "duckdb-cli.zip"
    if (
        not archive.exists()
        or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum
    ):
        url = f"https://github.com/duckdb/duckdb/releases/download/v{DUCKDB_VERSION}/duckdb_cli-{cli_target}.zip"
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise RuntimeError("DuckDB CLI checksum mismatch")
        archive.write_bytes(data)
    with zipfile.ZipFile(io.BytesIO(archive.read_bytes())) as zipped:
        (state / "duckdb").write_bytes(zipped.read("duckdb"))
    (state / "duckdb").chmod(0o755)
    print(f"DuckDB {duckdb.__version__}, DuckFlight {RELEASE}, {target}")


def local_database(state: Path):
    return duckdb.connect(
        str(state / "hits.db"), config={"allow_unsigned_extensions": "true"}
    )


def connect(state: Path):
    server = json.loads((state / "server.json").read_text())
    return dbapi.connect(
        f"grpc://{server['address']}",
        db_kwargs={
            "username": "clickbench",
            "password": (state / "password").read_text(),
        },
        autocommit=True,
    )


def check(state: Path) -> None:
    with connect(state) as connection, connection.cursor() as cursor:
        cursor.execute("select 1")
        if cursor.fetchall() != [(1,)]:
            raise RuntimeError("unexpected readiness response")


def serve(state: Path, nonce: str) -> None:
    stopped = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stopped.set())
    listener = state / "listener.csv"
    listener.unlink(missing_ok=True)
    process = subprocess.Popen(
        [
            str(state / "duckdb"),
            "-unsigned",
            "-bail",
            "-init",
            os.devnull,
            str(state / "hits.db"),
        ],
        stdin=subprocess.PIPE,
        text=True,
    )
    address = None
    try:
        process.stdin.write(
            f"load {sql_string(state / 'duckflight.duckdb_extension')};\n"
            "copy (select address from duckflight_flight_serve('127.0.0.1:0', "
            f"{sql_string(state / 'auth.toml')})) to {sql_string(listener)} (format csv, header false);\n"
        )
        process.stdin.flush()
        deadline = time.monotonic() + 25
        while address is None:
            if process.poll() is not None:
                raise RuntimeError(
                    f"DuckDB CLI exited with status {process.returncode}"
                )
            if stopped.is_set() or time.monotonic() >= deadline:
                raise TimeoutError(
                    "DuckDB CLI listener startup interrupted or timed out"
                )
            if listener.exists():
                contents = listener.read_text()
                if contents.endswith("\n"):
                    address = next(csv.reader([contents.strip()]))[0]
            if address is None:
                stopped.wait(0.05)
        (state / "server.json").write_text(
            json.dumps({"address": address, "nonce": nonce})
        )
        while not stopped.wait(0.25):
            if process.poll() is not None:
                raise RuntimeError(
                    f"DuckDB CLI exited with status {process.returncode}"
                )
    finally:
        try:
            if process.poll() is None:
                if address is not None:
                    process.stdin.write(
                        f"select * from duckflight_stop('flight', {sql_string(address)});\n"
                    )
                process.stdin.write(".quit\n")
                process.stdin.flush()
                process.wait(timeout=20)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            process.stdin.close()
            listener.unlink(missing_ok=True)
            (state / "server.json").unlink(missing_ok=True)


def process_owned(pid: int, nonce: str) -> bool:
    result = subprocess.run(
        ["ps", "-ww", "-p", str(pid), "-o", "args="],
        capture_output=True,
        text=True,
        check=False,
    )
    return (
        result.returncode == 0
        and str(ROOT / "harness.py") in result.stdout
        and nonce in result.stdout
    )


def process_alive(pid: int) -> bool:
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        capture_output=True,
        text=True,
        check=False,
    )
    status = result.stdout.strip()
    return result.returncode == 0 and bool(status) and not status.startswith("Z")


def start(state: Path) -> None:
    pid_path = state / "process.json"
    if pid_path.exists() and process_owned(**json.loads(pid_path.read_text())):
        check(state)
        return
    (state / "server.json").unlink(missing_ok=True)
    if not (state / "password").exists():
        password = secrets.token_urlsafe(32)
        salt = secrets.token_bytes(16)
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 10000).hex()
        (state / "password").write_text(password)
        (state / "password").chmod(0o600)
        (state / "auth.toml").write_text(
            f'[users.clickbench]\npassword_hash = "{digest}"\nsalt = {list(salt)}\niterations = 10000\n'
        )
        (state / "auth.toml").chmod(0o600)
    nonce = secrets.token_hex(16)
    with (state / "server.log").open("a") as log:
        process = subprocess.Popen(
            [
                sys.executable,
                str(ROOT / "harness.py"),
                "serve",
                "--state",
                str(state),
                "--nonce",
                nonce,
            ],
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=log,
            start_new_session=True,
        )
    pid_path.write_text(json.dumps({"pid": process.pid, "nonce": nonce}))
    try:
        for _ in range(120):
            if process.poll() is not None:
                raise RuntimeError(f"host exited: see {state / 'server.log'}")
            if (state / "server.json").exists():
                check(state)
                return
            time.sleep(0.25)
        raise TimeoutError(f"host did not start: see {state / 'server.log'}")
    except BaseException:
        stop(state)
        raise


def stop(state: Path) -> None:
    pid_path = state / "process.json"
    if not pid_path.exists():
        wait_database_released(state)
        return
    process = json.loads(pid_path.read_text())
    if process_alive(process["pid"]):
        if not process_owned(**process):
            raise RuntimeError(
                "PID is alive but ownership is unverified; refusing to stop"
            )
        os.kill(process["pid"], signal.SIGTERM)
        for _ in range(240):
            # Command-line ownership can disappear during exit before kernel
            # file cleanup finishes. Wait for process exit, not missing argv.
            if not process_alive(process["pid"]):
                break
            time.sleep(0.25)
        else:
            raise TimeoutError(
                f"host {process['pid']} did not stop; refusing a cold restart"
            )
    wait_database_released(state)
    pid_path.unlink()
    (state / "server.json").unlink(missing_ok=True)


def wait_database_released(state: Path) -> None:
    if not (state / "hits.db").exists():
        return
    deadline = time.monotonic() + 30
    while True:
        try:
            with local_database(state):
                return
        except duckdb.IOException as error:
            if "Could not set lock" not in str(error) or time.monotonic() >= deadline:
                raise
            # Process status alone is insufficient during final native-thread
            # teardown. Verify that the next host can actually acquire the DB.
            time.sleep(0.1)


@contextmanager
def query_result(connection, sql: str):
    # These statements have no bound parameters. DB-API execute prepares them
    # first, adding a metadata RPC and native planning that direct Flight SQL
    # execution does not need. Use ADBC's public direct-execution API instead.
    with AdbcStatement(connection.adbc_connection) as statement:
        statement.set_sql_query(sql)
        stream, _ = statement.execute_query()
        with pyarrow.RecordBatchReader.from_stream(stream) as reader:
            yield reader.read_all()


def query(state: Path) -> None:
    sql = sys.stdin.read()
    # Exclude interpreter startup and authentication, as with a connected SQL
    # client. Include execution, complete transfer and Python row conversion.
    with connect(state) as connection:
        began = time.perf_counter()
        with query_result(connection, sql) as table:
            rows = list(zip(*(column.to_pylist() for column in table.columns)))
            # As with the DB-API cursor and native Flight clients, teardown is
            # outside the timer. The complete stream and rows are already read.
            elapsed = time.perf_counter() - began
        writer = csv.writer(sys.stdout, lineterminator="\n")
        writer.writerow(table.column_names)
        writer.writerows(rows)
    print(f"{elapsed:.9f}", file=sys.stderr)


def load(state: Path) -> None:
    parquet = ROOT / "hits.parquet"
    if not parquet.is_file():
        raise FileNotFoundError("download the standard hits.parquet before loading")
    stop(state)
    # Do not silently replace an existing dataset: use a fresh state directory.
    # Match the native DuckDB and GizmoSQL ClickBench entries. The Python
    # connection API has no storage_version option; ATTACH owns that setting.
    with duckdb.connect() as database:
        database.execute(
            f"attach {sql_string(state / 'hits.db')} as clickbench (storage_version 'latest')"
        )
        database.execute("use clickbench")
        database.execute((ROOT / "create.sql").read_text())
        database.execute(
            "insert into hits select * replace (make_date(EventDate) as EventDate, "
            "epoch_ms(EventTime * 1000) as EventTime, "
            "epoch_ms(ClientEventTime * 1000) as ClientEventTime, "
            "epoch_ms(LocalEventTime * 1000) as LocalEventTime) "
            f"from read_parquet({sql_string(parquet)}, binary_as_string=true)"
        )
        count = database.execute("select count(*) from hits").fetchone()[0]
        if count != EXPECTED_ROWS:
            raise RuntimeError(
                f"partial dataset: {count} rows, expected {EXPECTED_ROWS}"
            )
        database.execute("checkpoint")
    start(state)


def data_size(state: Path) -> None:
    paths = [state / "hits.db", state / "hits.db.wal"]
    print(sum(path.stat().st_size for path in paths if path.exists()))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = {
        "install": install,
        "start": start,
        "stop": stop,
        "check": check,
        "query": query,
        "load": load,
        "data-size": data_size,
    }
    parser.add_argument("command", choices=[*commands, "serve"])
    parser.add_argument(
        "--state",
        type=Path,
        default=Path(os.environ.get("DUCKFLIGHT_BENCH_STATE", ROOT / ".state")),
    )
    parser.add_argument("--nonce", default="")
    args = parser.parse_args()
    state = args.state.resolve()
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    if duckdb.__version__ != DUCKDB_VERSION:
        raise RuntimeError(
            f"expected DuckDB {DUCKDB_VERSION}, got {duckdb.__version__}"
        )
    if args.command == "serve":
        serve(state, args.nonce)
    else:
        commands[args.command](state)


if __name__ == "__main__":
    main()
