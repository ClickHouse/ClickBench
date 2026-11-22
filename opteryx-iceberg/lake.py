"""Registers the Iceberg REST catalog of lib/iceberg/env.sh as the Opteryx
workspace `lake`, so the table is `lake.clickbench.hits`.

opteryx-core reads its S3 endpoint and key from AWS_S3_ENDPOINT /
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_REGION, which ./start and
./load export from the LAKE_ variables before Python starts. opteryx-iceberg
writes and reads every Iceberg file through that one identity; pyiceberg is
only the REST client.
"""

import os

from opteryx.connectors import register_workspace
from opteryx.connectors.opteryx_connector import OpteryxConnector
from opteryx_iceberg import IcebergMetastore


def register() -> None:
    env = os.environ
    register_workspace(
        "lake",
        OpteryxConnector,
        catalog=IcebergMetastore,
        catalog_type="rest",
        uri=env["LAKE_CATALOG_URI"],
        warehouse=env["LAKE_WAREHOUSE"],
        credential=f"{env['LAKE_CLIENT_ID']}:{env['LAKE_CLIENT_SECRET']}",
        **{"oauth2-server-uri": env["LAKE_OAUTH_URI"]},
    )
