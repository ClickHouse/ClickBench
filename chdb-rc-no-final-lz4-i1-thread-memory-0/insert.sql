INSERT INTO clickbench.hits
SELECT *
FROM file('hits.csv')
SETTINGS max_insert_threads = 1;
