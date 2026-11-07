-- The Iceberg REST catalog as the catalog `lake`. The placeholders are
-- substituted from lib/iceberg/env.sh by ./load.
CREATE CATALOG lake
PROPERTIES
(
    "type" = "iceberg",
    "iceberg.catalog.type" = "rest",
    "iceberg.rest.uri" = "{LAKE_CATALOG_URI}",
    "warehouse" = "{LAKE_WAREHOUSE}",
    "iceberg.rest.security.type" = "oauth2",
    "iceberg.rest.oauth2.credential" = "{LAKE_CLIENT_ID}:{LAKE_CLIENT_SECRET}",
    "iceberg.rest.oauth2.server-uri" = "{LAKE_OAUTH_URI}",
    "iceberg.rest.oauth2.scope" = "catalog",
    "s3.endpoint" = "{LAKE_S3_ENDPOINT}",
    "s3.region" = "{AWS_REGION}",
    "s3.access_key" = "{AWS_ACCESS_KEY_ID}",
    "s3.secret_key" = "{AWS_SECRET_ACCESS_KEY}",
    "use_path_style" = "{LAKE_S3_PATH_STYLE}"
);
