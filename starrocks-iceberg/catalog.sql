-- The Iceberg REST catalog as the external catalog `lake`. The placeholders
-- are substituted from lib/iceberg/env.sh by ./load.
CREATE EXTERNAL CATALOG lake
PROPERTIES
(
    "type" = "iceberg",
    "iceberg.catalog.type" = "rest",
    "iceberg.catalog.uri" = "{LAKE_CATALOG_URI}",
    "iceberg.catalog.warehouse" = "{LAKE_WAREHOUSE}",
    "iceberg.catalog.security" = "oauth2",
    "iceberg.catalog.oauth2.credential" = "{LAKE_CLIENT_ID}:{LAKE_CLIENT_SECRET}",
    "iceberg.catalog.oauth2.server-uri" = "{LAKE_OAUTH_URI}",
    "iceberg.catalog.oauth2.scope" = "catalog",
    "aws.s3.endpoint" = "{LAKE_S3_ENDPOINT}",
    "aws.s3.enable_path_style_access" = "{LAKE_S3_PATH_STYLE}",
    "aws.s3.enable_ssl" = "{LAKE_S3_USE_SSL}",
    "aws.s3.region" = "{AWS_REGION}",
    "aws.s3.use_instance_profile" = "false",
    "aws.s3.access_key" = "{AWS_ACCESS_KEY_ID}",
    "aws.s3.secret_key" = "{AWS_SECRET_ACCESS_KEY}"
);
