-- A VIEW over the public parquet on S3; nothing is copied into MotherDuck
-- storage. The view is stored in the MotherDuck database, and read_parquet
-- runs on the remote Duckling, which reads the public bucket over anonymous
-- HTTPS (no credentials needed, and no IMDS probing as with s3://).
CREATE VIEW hits AS
SELECT *
    REPLACE (make_date(EventDate) AS EventDate)
FROM read_parquet('https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/hits_compatible/hits.parquet', binary_as_string=True);

CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
