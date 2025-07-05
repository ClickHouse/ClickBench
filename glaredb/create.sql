CREATE TEMP VIEW hits AS
  SELECT * REPLACE (EventDate::DATE AS EventDate)
    FROM read_parquet('./data/hits.parquet');
