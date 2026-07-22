SELECT cab_type, count(*) FROM trips GROUP BY cab_type;
SELECT passenger_count, avg(total_amount) FROM trips GROUP BY passenger_count;
SELECT passenger_count, toYear(pickup_date) AS year, count(*) FROM trips GROUP BY passenger_count, year;
SELECT passenger_count, toYear(pickup_date) AS year, round(trip_distance) AS distance, count(*) FROM trips GROUP BY passenger_count, year, distance ORDER BY year, count(*) DESC;
