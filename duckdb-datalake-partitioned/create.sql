SET home_directory='/root';
INSTALL httpfs;
LOAD httpfs;

CREATE VIEW hits AS
SELECT *
    REPLACE (make_date(EventDate) AS EventDate)
FROM read_parquet('s3://clickhouse-public-datasets/hits_compatible/athena_partitioned/hits_*.parquet' binary_as_string=True);

CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
