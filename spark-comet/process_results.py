#!/usr/bin/env python3

import json
import re
import subprocess
import sys
from datetime import date


def get_data_size():
    # basically a duplicate of `benchmark.sh`
    result = subprocess.run(["du", "-b", "hits.parquet"], capture_output=True, text=True)
    return int(result.stdout.split()[0])


def process_times(log_file):
    results = []
    current_array = []

    with open(log_file) as f:
        for line in f:
            if line.startswith("Time: "):
                value = float(line.strip().replace("Time: ", ""))
                current_array.append(value)
            elif line.startswith("Failure!"):
                current_array.append(None)

            if len(current_array) == 3:
                results.append(current_array)
                current_array = []

    return results


def get_comment():
    with open("benchmark.sh") as f:
        for line in f:
            if "comet.jar" in line:
                comet_version = re.search(r"(.{5}).jar", line).group(1)
            elif "pyspark" in line:
                pyspark_version = re.search(r"pyspark==([^\s]+)", line).group(1)
    return f"Using Comet {comet_version} with Spark {pyspark_version}"


def main():
    machine = sys.argv[1] if len(sys.argv) > 1 else "unknown"

    data = {
        "system": "Spark (Comet)",
        "date": date.today().isoformat(),
        "machine": machine,
        "cluster_size": 1,
        "proprietary": "no",
        "tuned": "no",
        "comment": get_comment(),
        "tags": ["Java", "Rust", "column-oriented", "Spark derivative", "DataFusion", "Parquet"],
        "load_time": 0,
        "data_size": get_data_size(),
        "result": process_times("log.txt"),
    }

    print(json.dumps(data, indent=4))


if __name__ == "__main__":
    main()
