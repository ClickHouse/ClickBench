-- The Iceberg REST catalog as the catalog `lake`. The placeholders are
-- substituted from lib/iceberg/env.sh by ./load. The quoted options are
-- passed to the REST catalog of iceberg-rust as they are.
CREATE CATALOG lake TYPE = ICEBERG CONNECTION = (
    TYPE = 'rest'
    ADDRESS = '{LAKE_CATALOG_URI}'
    WAREHOUSE = '{LAKE_WAREHOUSE}'
    "credential" = '{LAKE_CLIENT_ID}:{LAKE_CLIENT_SECRET}'
    "oauth2-server-uri" = '{LAKE_OAUTH_URI}'
    "scope" = 'catalog'
    "s3.endpoint" = '{LAKE_S3_ENDPOINT}'
    "s3.path-style-access" = '{LAKE_S3_PATH_STYLE}'
    "s3.region" = '{AWS_REGION}'
    "s3.access-key-id" = '{AWS_ACCESS_KEY_ID}'
    "s3.secret-access-key" = '{AWS_SECRET_ACCESS_KEY}'
);
