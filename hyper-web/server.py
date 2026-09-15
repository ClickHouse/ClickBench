import json
import os
import signal
from pathlib import Path

from tableauhyperapi import Connection, CreateMode, HyperProcess, Telemetry


def terminate(*_):
    raise SystemExit(0)


def provider_config():
    return {
        "providers": [
            {"type": "transient-file", "name": "transient"},
            {
                "type": "s3-single-file",
                "name": "clickbench-s3",
                "s3-bucket": os.environ["HYPER_WEB_S3_BUCKET"],
                "s3-region": os.environ["HYPER_WEB_S3_REGION"],
                "s3-prefix": os.environ["HYPER_WEB_S3_PREFIX"],
                "s3-credentials": {
                    "type": "explicit",
                    "access-key-id": "",
                    "secret-access-key": "",
                },
                "allowed-access-mode": "read-only",
            },
        ],
        "default": "clickbench-s3",
        "default-transient": "transient",
    }


def publish(path, value):
    temporary_path = path.with_suffix(path.suffix + ".tmp")
    temporary_path.write_text(value)
    os.replace(temporary_path, path)


signal.signal(signal.SIGTERM, terminate)
signal.signal(signal.SIGINT, terminate)

with HyperProcess(
    telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU,
    parameters={
        "storage_providers": json.dumps(provider_config()),
        "blockpartition_prefetch_lookahead": "0",
    },
) as hyper:
    # Attach before publishing the endpoint. Its presence therefore means the
    # process is ready for queries, including after every cold-query restart.
    with Connection(
        hyper.endpoint,
        os.environ["HYPER_WEB_S3_DATABASE"],
        CreateMode.NONE,
        parameters={"access_mode": "readonly"},
    ):
        publish(Path("server.endpoint"), hyper.endpoint.connection_descriptor)

        while True:
            signal.pause()
