SELECT avg(c1) FROM (SELECT Year, Month, count(*) AS c1 FROM ontime GROUP BY Year, Month)
SELECT DayOfWeek, count(*) AS c FROM ontime WHERE Year>=2000 AND Year<=2008 GROUP BY DayOfWeek ORDER BY c DESC
SELECT DayOfWeek, count(*) AS c FROM ontime WHERE DepDelay>10 AND Year>=2000 AND Year<=2008 GROUP BY DayOfWeek ORDER BY c DESC
SELECT Origin, count(*) AS c FROM ontime WHERE DepDelay>10 AND Year>=2000 AND Year<=2008 GROUP BY Origin ORDER BY c DESC LIMIT 10
SELECT IATA_CODE_Reporting_Airline AS Carrier, count(*) FROM ontime WHERE DepDelay>10 AND Year=2007 GROUP BY Carrier ORDER BY count(*) DESC
SELECT Carrier, c, c2, c*100/c2 AS c3 FROM (SELECT IATA_CODE_Reporting_Airline AS Carrier, count(*) AS c FROM ontime WHERE DepDelay>10 AND Year=2007 GROUP BY Carrier) q JOIN (SELECT IATA_CODE_Reporting_Airline AS Carrier, count(*) AS c2 FROM ontime WHERE Year=2007 GROUP BY Carrier) qq USING Carrier ORDER BY c3 DESC
SELECT Carrier, c, c2, c*100/c2 AS c3 FROM (SELECT IATA_CODE_Reporting_Airline AS Carrier, count(*) AS c FROM ontime WHERE DepDelay>10 AND Year>=2000 AND Year<=2008 GROUP BY Carrier) q JOIN (SELECT IATA_CODE_Reporting_Airline AS Carrier, count(*) AS c2 FROM ontime WHERE Year>=2000 AND Year<=2008 GROUP BY Carrier) qq USING Carrier ORDER BY c3 DESC
SELECT Year, c1/c2 FROM (SELECT Year, count(*)*100 AS c1 FROM ontime WHERE DepDelay>10 GROUP BY Year) q JOIN (SELECT Year, count(*) AS c2 FROM ontime GROUP BY Year) qq USING (Year) ORDER BY Year
SELECT DestCityName, uniqExact(OriginCityName) AS u FROM ontime WHERE Year >= 2000 AND Year <= 2010 GROUP BY DestCityName ORDER BY u DESC LIMIT 10
SELECT Year, count(*) AS c1 FROM ontime GROUP BY Year
SELECT min(Year), max(Year), IATA_CODE_Reporting_Airline AS Carrier, count(*) AS cnt, sum(ArrDelayMinutes>30) AS flights_delayed, round(sum(ArrDelayMinutes>30)/count(*),2) AS rate FROM ontime WHERE DayOfWeek NOT IN (6,7) AND OriginState NOT IN ('AK', 'HI', 'PR', 'VI') AND DestState NOT IN ('AK', 'HI', 'PR', 'VI') AND FlightDate < '2010-01-01' GROUP BY Carrier HAVING cnt>100000 AND max(Year)>1990 ORDER BY rate DESC LIMIT 1000
