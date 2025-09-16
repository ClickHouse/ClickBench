INSERT INTO hits
SELECT * REPLACE (
    make_date(EventDate) AS EventDate,
    epoch_ms(EventTime * 1000) AS EventTime,
    epoch_ms(ClientEventTime * 1000) AS ClientEventTime,
    epoch_ms(LocalEventTime * 1000) AS LocalEventTime)
FROM read_parquet('hits.parquet', binary_as_string=True);
