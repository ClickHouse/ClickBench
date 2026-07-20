SELECT toYear(date) AS year, round(avg(price)) AS price FROM uk_price_paid GROUP BY year ORDER BY year
SELECT toYear(date) AS year, round(avg(price)) AS price FROM uk_price_paid WHERE town = 'LONDON' GROUP BY year ORDER BY year
SELECT town, district, count() AS c, round(avg(price)) AS price FROM uk_price_paid WHERE date >= '2020-01-01' GROUP BY town, district HAVING c >= 100 ORDER BY price DESC LIMIT 100
