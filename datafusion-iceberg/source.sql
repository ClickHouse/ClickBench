CREATE EXTERNAL TABLE hits_parquet
STORED AS PARQUET
LOCATION 'partitioned/'
OPTIONS ('binary_as_string' 'true');
