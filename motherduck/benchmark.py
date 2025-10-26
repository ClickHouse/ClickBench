import duckdb
import json
import os
import sys
import subprocess
import timeit
import time

DEFAULT_OUTPUT_FILE = 'log'

def convert_human_readable_size_to_bytes(size_with_unit):
    # Parse the size string (e.g., "22.0 GiB", "100 MB", "0 bytes")
    parts = size_with_unit.split()
    if len(parts) == 2:
        value = float(parts[0])
        unit = parts[1].lower()

        # Convert to bytes
        multipliers = {
            'bytes': 1,
            'byte': 1,
            'kb': 1024,
            'kib': 1024,
            'mb': 1024**2,
            'mib': 1024**2,
            'gb': 1024**3,
            'gib': 1024**3,
            'tb': 1024**4,
            'tib': 1024**4
        }

        bytes_value = int(value * multipliers.get(unit, 1))
        return bytes_value
    else:
        raise Exception(f"Unparseable human readable database size: {size_with_unit}")

def write_result_to_file(run_metadata, query_results):
    filename = os.getenv('motherduck_instance_type', DEFAULT_OUTPUT_FILE) + ".json"
    with open(filename, 'w') as f:
        print("{", file=f)
        for key in run_metadata:
            print(f'\t"{key}": {json.dumps(run_metadata[key])},', file=f)

        print('\t"result": [', file=f)
        num_lines = len(query_results)
        for i in range(num_lines):
            print(f"\t\t{query_results[i]}", end='', file=f)
            print("," if i < num_lines - 1 else "", file=f)

        print("\t]\n}", file=f)

def load_data(run_metadata):
    con = duckdb.connect(database="md:", read_only=False)
    print('Connected to MotherDuck; loading the data', file=sys.stderr)

    con.execute('CREATE OR REPLACE DATABASE clickbench')
    con.execute('USE clickbench')

    # disable preservation of insertion order
    con.execute("SET preserve_insertion_order=false")

    # perform the actual load
    start = timeit.default_timer()
    con.execute(open("create.sql").read())
    file = '''https://datasets.clickhouse.com/hits_compatible/hits.parquet'''
    # The parquet file doesn't have the timestamps as timestamps, so we
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
    run_metadata["load_time"] = round(end - start, 3)

    # Print the database size. For MotherDuck, we get a formatted string.
    result = con.execute("""
       SELECT database_size
       FROM pragma_database_size()
       WHERE database_name = 'clickbench'
       """).fetchone()

    if result and result[0]:
        print(f"Human readable database size: {result[0]}", file=sys.stderr)
        run_metadata["data_size"] = convert_human_readable_size_to_bytes(result[0])
    else:
        raise Exception(f"pragma_database_size() did not return the expected value: {result}")

    print(f'Finished loading the data in {run_metadata["load_time"]}; data size = {run_metadata["data_size"]}', file=sys.stderr)

def run_queries():
    # Going through a shell script (run.sh) and back to python (query.py) is not functionally necessary,
    # but will make sure run.sh keeps working as intended

    try:
        # Run the benchmark script
        result = subprocess.run(
            ["./run.sh"],
            stdout=subprocess.PIPE,
            text=True,
            timeout=3600,  # 1 hour timeout
        )

        if result.returncode != 0:
            raise Exception(f"Benchmark failed: {result.stderr}")

        # Process the output to create result.json
        return result.stdout
    except subprocess.TimeoutExpired:
        raise Exception(f"Benchmark timed out after 1 hour")
    except Exception as e:
        raise Exception(f"Benchmark failed: {str(e)}")

if __name__ == "__main__":
    instance_type = os.getenv('motherduck_instance_type', 'unknown instance type')
    run_metadata = {
        "system": "MotherDuck",
        "date": time.strftime("%Y-%m-%d"),
        "machine": f"Motherduck: {instance_type}",
        "cluster_size": 1,
        "proprietary": "yes",
        "tuned": "no",
        "tags": ["C++", "column-oriented", "serverless", "managed"],
    }
    load_data(run_metadata)

    query_output = run_queries()

    write_result_to_file(run_metadata, query_output.strip().split('\n'))
