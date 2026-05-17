-- slothdb's parser does not support DuckDB's `SELECT * REPLACE (...)`
-- syntax, so we cannot transparently rewrite EventTime/EventDate inside
-- the view definition. Leave the columns as their parquet types
-- (EventDate as INT32 days-since-epoch, *Time as INT32 unix seconds);
-- Q19/Q43 may fail with a type error on extract/DATE_TRUNC, matching
-- slothdb's own bench/run.py setup which queries `FROM 'hits.parquet'`
-- directly without type rewrites.
CREATE VIEW hits AS SELECT * FROM 'hits.parquet';
