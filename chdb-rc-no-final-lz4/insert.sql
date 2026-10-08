INSERT INTO clickbench.hits
SELECT *
FROM file('hits.csv');
