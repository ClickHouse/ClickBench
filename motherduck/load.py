#!/usr/bin/env python3

import duckdb
import timeit
import psutil

con = duckdb.connect(database="md:", read_only=False)
con.execute('CREATE OR REPLACE DATABASE clickbench')
con.execute('USE clickbench')

# disable preservation of insertion order
con.execute("SET preserve_insertion_order=false")

# perform the actual load
print("Will load the data")
start = timeit.default_timer()
con.execute(open("create.sql").read())
file = '''https://datasets.clickhouse.com/hits_compatible/hits.parquet'''
# The parquet file doen't have the timestamps as timestamps, so we 
# need to coerce them into proper timestamps.
con.execute(f"""
    INSERT INTO hits 
    SELECT *
    REPLACE
    (epoch_ms(EventTime * 1000) AS EventTime,
     epoch_ms(ClientEventTime * 1000) AS ClientEventTime,
     epoch_ms(LocalEventTime * 1000) AS LocalEventTime,
     DATE '1970-01-01' + INTERVAL (EventDate) DAYS AS EventDate)
    FROM read_parquet('{file}', binary_as_string=True)
     """)
end = timeit.default_timer()
print(end - start)

# Print the database size.
print(con.execute("""
   SELECT database_size 
   FROM pragma_database_size()
   WHERE database_name = 'clickbench'
   """).fetchall())
