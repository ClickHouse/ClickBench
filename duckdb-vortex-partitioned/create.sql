LOAD vortex; 

CREATE VIEW hits AS
    SELECT * REPLACE (make_date(EventDate) AS EventDate)
    FROM read_vortex('hits_*.vortex');
CREATE MACRO toDateTime(t) AS epoch_ms(t * 1000);
