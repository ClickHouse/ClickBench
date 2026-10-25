"""ClickBench hooks for the released Duckflight extension."""

from __future__ import annotations

import argparse
import csv
import fnmatch
import gzip
import hashlib
import io
import json
import os
import platform
import secrets
import signal
import subprocess
import sys
import tarfile
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from contextlib import contextmanager
from pathlib import Path

import duckdb
import pyarrow
from adbc_driver_flightsql import dbapi
from adbc_driver_manager import AdbcStatement

IMPLEMENTATION = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("DUCKFLIGHT_BENCH_ENTRY", IMPLEMENTATION)).resolve()
RELEASE = "core-v0.1.14 / signed DuckDB 2.0.0"
DUCKDB_VERSION = "2.0.0"
DUCKDB_COMMIT = "d54cbbe3df"
CHECKSUMS = {
    "linux_amd64": "928d8ef5c91c185873eacc960e7b6e574bfedb527b2d6fc2ad3eda553fc34e68",
    "linux_arm64": "a52ee234af7614c0d7ef31e43dbe71301155ae60a9c76217d4064bb5acf58729",
    "osx_amd64": "966d794cce2ac8c32515ba677100e58a378e3f187c4f307aa88e6cf5dfb859c0",
    "osx_arm64": "52b3117d8f96036f1164608fcc369192ce498610b53f91a97c36a6b498273833",
}
EXPECTED_ROWS = 99_997_497
LAKE_URL = (
    "https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/"
    "hits_compatible/hits.parquet"
)
CLI_ASSETS = {
    "linux_amd64": (
        "linux-amd64",
        "c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc",
    ),
    "linux_arm64": (
        "linux-arm64",
        "859e1875d2a9515fbb4bf8871061437a14af82320da68c753f094c4b776348fe",
    ),
    "osx_amd64": (
        "osx-amd64",
        "fbc7013ba09d117396dabf16783281c2add47fc01cdac4855464a03526dc96ee",
    ),
    "osx_arm64": (
        "osx-arm64",
        "188a36fe8883ef52e69165a0cbb6031ef679c8e6c448a1ce22951964149b7f96",
    ),
}


def sql_string(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def storage_mode() -> str:
    mode = os.environ.get("DUCKFLIGHT_BENCH_STORAGE", "native")
    if mode not in ("native", "datalake", "datalake-partitioned"):
        raise ValueError(
            "DUCKFLIGHT_BENCH_STORAGE must be native, datalake or datalake-partitioned"
        )
    return mode


def query_file() -> Path:
    return ROOT / "queries.sql"


def storage_settings() -> str:
    mode = storage_mode()
    if mode == "native":
        return ""
    settings = "set parquet_metadata_cache=true;\nload httpfs;\n"
    if mode == "datalake-partitioned":
        region = os.environ.get("DUCKFLIGHT_BENCH_S3_REGION", "eu-central-1")
        settings += (
            f"set s3_region={sql_string(region)};\n"
            "create or replace secret s3_anon (type s3, key_id '', secret '', "
            f"region {sql_string(region)});\n"
        )
    return settings


def install(state: Path) -> None:
    mode = storage_mode()
    os_name = {"Linux": "linux", "Darwin": "osx"}[platform.system()]
    arch = {"x86_64": "amd64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine()]
    target = f"{os_name}_{arch}"
    path = state / "duckflight.duckdb_extension"
    url = f"https://extensions.sidequery.dev/v{DUCKDB_VERSION}/{target}/duckflight.duckdb_extension.gz"
    request = urllib.request.Request(
        url, headers={"User-Agent": "duckflight-clickbench/2.0"}
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != CHECKSUMS[target]:
        raise RuntimeError("extension checksum mismatch")
    path.write_bytes(gzip.decompress(data))
    cli_target, checksum = CLI_ASSETS[target]
    archive = state / "duckdb-cli.tar.gz"
    if (
        not archive.exists()
        or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum
    ):
        url = f"https://github.com/duckdb/duckdb/releases/download/v{DUCKDB_VERSION}/duckdb-cli-{cli_target}.tar.gz"
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise RuntimeError("DuckDB CLI checksum mismatch")
        archive.write_bytes(data)
    with tarfile.open(fileobj=io.BytesIO(archive.read_bytes()), mode="r:gz") as packed:
        (state / "duckdb").write_bytes(packed.extractfile("duckdb").read())
    (state / "duckdb").chmod(0o755)
    version = (
        subprocess.check_output(
            [str(state / "duckdb"), "-csv", "-noheader", "-c", "pragma version"],
            text=True,
        )
        .strip()
        .split(",")
    )
    if version[:2] != [f"v{DUCKDB_VERSION}", DUCKDB_COMMIT]:
        raise RuntimeError(f"unexpected DuckDB CLI version: {version}")
    if mode != "native":
        with duckdb.connect() as database:
            database.execute("install httpfs from 'https://extensions.duckdb.org'")
    print(f"DuckDB {duckdb.__version__}, DuckFlight {RELEASE}, {target}")


def local_database(state: Path):
    database = duckdb.connect(
        str(state / "hits.db"), config={"allow_unsigned_extensions": "true"}
    )
    try:
        settings = storage_settings()
        if settings:
            database.execute(settings)
    except BaseException:
        database.close()
        raise
    return database


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
            "-no-agent",
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
        )
        process.stdin.write(storage_settings())
        process.stdin.write(
            "copy (select address from duckflight_flight_serve('127.0.0.1:0', "
            f"{sql_string(state / 'auth.toml')})) to {sql_string(listener)} (format csv, header false);\n"
        )
        process.stdin.flush()
        deadline = time.monotonic() + 120
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
        and str(IMPLEMENTATION / "harness.py") in result.stdout
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
                str(IMPLEMENTATION / "harness.py"),
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
        for _ in range(480):
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
    # first, adding a metadata RPC and native planning that direct execution
    # does not need. Use ADBC's public direct-execution API instead.
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
        null_text = os.environ.get("DUCKFLIGHT_BENCH_CSV_NULL")
        if null_text is None:
            writer.writerows(rows)
        else:
            # Validation distinguishes NULL from empty text; encoding stays
            # outside the query timer, matching the earlier client comparison.
            writer.writerows(
                [null_text if value is None else value for value in row] for row in rows
            )
    print(f"{elapsed:.9f}", file=sys.stderr)


def load(state: Path) -> None:
    if storage_mode() != "native":
        load_datalake(state)
        return
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


def lake_source() -> dict:
    mode = storage_mode()
    default = (
        "s3://clickhouse-public-datasets/hits_compatible/athena_partitioned/hits_*.parquet"
        if mode == "datalake-partitioned"
        else LAKE_URL
    )
    source = os.environ.get("DUCKFLIGHT_BENCH_PARQUET_SOURCE", default)
    if mode == "datalake":
        if not source.startswith(("https://", "http://")):
            raise ValueError("datalake mode requires a single Parquet HTTP(S) URL")
        request = urllib.request.Request(source, method="HEAD")
        with urllib.request.urlopen(request, timeout=120) as response:
            size = int(response.headers["Content-Length"])
        return {"mode": mode, "source": source, "data_size": size}
    parsed = urllib.parse.urlsplit(source)
    pattern = parsed.path.lstrip("/")
    if parsed.scheme != "s3" or not parsed.netloc or pattern.count("*") != 1:
        raise ValueError(
            "partitioned lake mode requires an s3:// bucket and one wildcard"
        )
    region = os.environ.get("DUCKFLIGHT_BENCH_S3_REGION", "eu-central-1")
    endpoint = f"https://{parsed.netloc}.s3.{region}.amazonaws.com/"
    params = {"list-type": "2", "prefix": pattern.split("*", 1)[0]}
    objects = []
    namespace = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    while True:
        with urllib.request.urlopen(
            endpoint + "?" + urllib.parse.urlencode(params), timeout=120
        ) as response:
            listing = ET.fromstring(response.read())
        for item in listing.findall("s3:Contents", namespace):
            key = item.findtext("s3:Key", namespaces=namespace)
            if key and fnmatch.fnmatchcase(key, pattern):
                objects.append(
                    {
                        "key": key,
                        "size": int(item.findtext("s3:Size", namespaces=namespace)),
                    }
                )
        if listing.findtext("s3:IsTruncated", namespaces=namespace) != "true":
            break
        token = listing.findtext("s3:NextContinuationToken", namespaces=namespace)
        if not token or token == params.get("continuation-token"):
            raise RuntimeError("S3 listing omitted a new continuation token")
        params["continuation-token"] = token
    if not objects:
        raise RuntimeError("partitioned lake source matched no objects")
    return {
        "mode": mode,
        "source": source,
        "region": region,
        "objects": objects,
        "data_size": sum(item["size"] for item in objects),
    }


def load_datalake(state: Path) -> None:
    storage = lake_source()
    source = storage["source"]
    stop(state)
    with local_database(state) as database:
        database.execute(
            "create view hits as select * replace (make_date(EventDate) as EventDate) "
            f"from read_parquet({sql_string(source)}, binary_as_string=true)"
        )
        database.execute("create macro toDateTime(t) as epoch_ms(t * 1000)")
        count = database.execute("select count(*) from hits").fetchone()[0]
        if count != EXPECTED_ROWS:
            raise RuntimeError(
                f"partial dataset: {count} rows, expected {EXPECTED_ROWS}"
            )
        database.execute("checkpoint")
    (state / "storage.json").write_text(json.dumps(storage))
    start(state)


def data_size(state: Path) -> None:
    if storage_mode() != "native":
        storage = json.loads((state / "storage.json").read_text())
        if storage["mode"] != storage_mode():
            raise RuntimeError("state storage mode differs from requested mode")
        print(storage["data_size"])
        return
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
