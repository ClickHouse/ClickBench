CREATE EXTERNAL TABLE hits_raw
STORED AS PARQUET
LOCATION 'partitioned'
OPTIONS ('binary_as_string' 'true');

CREATE VIEW hits AS
SELECT * EXCEPT ("EventDate"),
       CAST(CAST("EventDate" AS INTEGER) AS DATE) AS "EventDate"
FROM hits_raw;