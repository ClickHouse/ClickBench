SET home_directory='/root';
INSTALL httpfs;
LOAD httpfs;

-- Use the HTTPS URL directly instead of s3://. The s3:// scheme makes
-- DuckDB's S3 driver probe the EC2 instance-metadata service
-- (169.254.169.254) for IAM credentials before each request; in the
-- playground that probe is blocked by the SNI proxy and each query
-- waits the full IMDS timeout. HTTPS reads need no credentials for a
-- public bucket and hit the proxy directly.
CREATE VIEW hits AS
SELECT *
    REPLACE (make_date(EventDate) AS EventDate)
FROM read_parquet('https://clickhouse-public-datasets.s3.eu-central-1.amazonaws.com/hits_compatible/hits.parquet', binary_as_string=True);

CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
