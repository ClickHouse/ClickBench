CREATE EXTERNAL TABLE hits_raw STORED AS PARQUET LOCATION 'hits.parquet' OPTIONS ('binary_as_string' 'true');
CREATE VIEW hits AS SELECT * EXCEPT("EventDate"), CAST(CAST("EventDate" AS INT) AS DATE) AS "EventDate" FROM hits_raw;
