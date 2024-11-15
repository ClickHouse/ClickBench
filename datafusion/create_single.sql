CREATE EXTERNAL TABLE hits
STORED AS PARQUET
LOCATION 'hits.parquet'
OPTIONS ('binary_as_string' 'true');
