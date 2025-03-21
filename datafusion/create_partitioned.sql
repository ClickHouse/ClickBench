CREATE EXTERNAL TABLE hits
STORED AS PARQUET
LOCATION 'partitioned'
OPTIONS ('binary_as_string' 'true');
