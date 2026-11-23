CREATE VIEW hits AS
SELECT *
    REPLACE (make_date(EventDate) AS EventDate)
FROM read_parquet('hits_*.parquet', binary_as_string=True);

CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
