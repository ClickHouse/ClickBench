SET home_directory='/root';
INSTALL httpfs;
LOAD httpfs;

-- The s3:// scheme makes DuckDB probe the EC2 instance-metadata
-- service (169.254.169.254) for IAM credentials before every
-- request; in the playground that probe is blocked by the SNI proxy,
-- adding a long IMDS timeout to each query. Provide an explicit
-- empty credential so the chain stops at "config" and never reaches
-- IMDS. Public bucket accepts anonymous requests fine.
CREATE OR REPLACE SECRET s3_anon (
    TYPE S3,
    KEY_ID '',
    SECRET '',
    REGION 'eu-central-1'
);

CREATE VIEW hits AS
SELECT *
    REPLACE (make_date(EventDate) AS EventDate)
FROM read_parquet('s3://clickhouse-public-datasets/hits_compatible/athena_partitioned/hits_*.parquet', binary_as_string=True);

CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
