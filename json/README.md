# JSONBench: A Benchmark For Data Analytics on JSON

https://benchmark.clickhouse.com/json/

## Overview

This benchmark compares the native JSON support of analytical databases.

The [dataset](https://clickhouse.com/blog/json-bench-clickhouse-vs-mongodb-elasticsearch-duckdb-postgresql#the-json-dataset---a-billion-bluesky-events) is a collection of files containing JSON objects delimited by newline (ndjson).
It was obtained using Jetstream to collect Bluesky events.
The dataset contains 1 billion Bluesky events in 1000 files of one million events each, and is hosted on a public S3 bucket.

We wrote a [detailed blog post](https://clickhouse.com/blog/json-bench-clickhouse-vs-mongodb-elasticsearch-duckdb-postgresql) about JSONBench, explaining how it works and showcasing benchmark results for five databases: ClickHouse, MongoDB, Elasticsearch, DuckDB, and PostgreSQL.

JSONBench was originally published in its own repository, https://github.com/ClickHouse/JSONBench.
In 2026 it moved here, into the `json/` directory of ClickBench, to share its automation: the results are reproduced on fresh cloud machines launched from GitHub Actions, sent to a database, and collected into this directory automatically, the same way as for ClickBench, the [Versions Benchmark](../versions/README.md) and the [Hardware Benchmark](../hardware/README.md).

## Principles

### Reproducibility

It is easy to reproduce every test in a fully automated way (although for some systems it may take from several hours to days).
The test setup is documented and uses inexpensive cloud VMs.
The test process is available in the form of shell scripts, covering the installation of each database, loading of the data, running the workload, and collecting the result numbers.

### Realism

The dataset represents real-world production data.
The realistic data distribution allows to account appropriately for compression, indices, codecs, custom data structures, etc., something that is not possible with most random data generators.
JSONBench tests various aspects of the hardware as well: some queries require high storage throughput, some queries benefit from a large number of CPU cores, and some benefit from single-core speed, some queries benefit from high main memory bandwidth.

### Fairness

Databases must be benchmarked using their default settings.
As an exception, it is okay to specify non-default settings if they are a prerequisite for running the benchmark (example: increasing the maximum JVM heap size).
Non-mandatory settings, especially settings related to workload tuning, are not allowed.

Some databases provide a native JSON data type that flattens nested JSON documents at insertion time to a single level, typically using `.` as separator between levels.
We consider this a grey zone.
On the one hand, flattening removes the possibility to restore the original documents.
On the other hand, flattening is in many practical situations acceptable.
The dashboard provides a toggle which allows to show or hide databases that use flattening (`retains_structure` in `template.json` and the results).
In the scope of JSONBench, we generally discourage flattening.

Other forms of flattening, in particular flattening JSON into multiple non-JSON colums at insertion time, are disallowed.

It is allowed to index the data using clustered indexes (= specifying the table sort order) or non-clustered indexes (= additional data structures, e.g. B-trees).
We recognize that there are pros and cons of this approach.

Pros:
- The JSON documents in JSONBench expose a common and rather static structure. Many real-world use cases expose similar patterns. It is a widely used practice to create indexes based on the anticipated data structure.
- The original [blog post](https://clickhouse.com/blog/json-bench-clickhouse-vs-mongodb-elasticsearch-duckdb-postgresql#some-json-paths-can-be-used-for-indexes-and-data-sorting) made use of indexes. Disallowing clustered indexes entirely would invalidate the original measurements.

Cons:
- There may be other real-world use cases where the JSON documents are highly dynamic (they share no common structure). In these cases, indexes are not useful.
- Many databases use indexes to prune the set of scanned data ranges or retrieve result rows directly (no scan). As a result, the benchmark indirectly also measures the effectiveness of such access path optimization techniques.
- Likewise, clustered indexes impact how well the data can be compressed. Again, this affects query runtimes indirectly.
- In some databases, clustered indexes must be build on top of flattened (e.g. concatenated and materialized) JSON documents. This technically contradicts the previous statement that flattening is discouraged.

It is not allowed to cache query results (or generally: intermediate results at the end of the query processing pipeline) between hot runs.

## Goals

The goal is to advance the possibilities of data analytics on semistructured data.
This benchmark is influenced by [ClickBench](https://github.com/ClickHouse/ClickBench), which was published in 2022 and has helped in improving performance, capabilities, and stability of many analytics databases.
We would like to see JSONBench having a similar impact on the community.

## Limitations

The benchmark focuses on data analytics queries over JSON documents rather than single-value retrieval or data modification operations.

The load time is recorded, but it is not a part of the original methodology, and many systems require a multi-step data preparation process, which makes it difficult to compare.

## How it works

The benchmark runs on four dataset sizes: 1 million, 10 million, 100 million and 1 billion documents (the first 1, 10, 100 or all 1000 files).
Every (system, dataset size) pair runs on its own fresh machine: by default an `m6i.8xlarge` (32 vCPU, 128 GB RAM, the machine of the original JSONBench results) with a 2000 GB gp3 root volume (16000 IOPS, 1000 MB/s), Ubuntu 24.04.

Every system has a directory with the same scripts as in the main ClickBench (see `lib/benchmark-common.sh` for the details):

- `benchmark.sh`: the entry point, `./benchmark.sh <size>`, where `<size>` is 1, 10, 100 or 1000; it sets a few options and runs the shared driver, `lib/benchmark-common.sh`;
- `install`, `start`, `check`, `stop`: install the system, start and stop the server, and check that it accepts queries;
- `load`: create the table and load the first `$BENCH_FILES` files from `$BENCH_DATA_DIR`;
- `query`: run one query read from stdin, print its runtime in seconds as the last line of stderr;
- `data-size`: print the size of the data and indexes in bytes; `count`: print the number of loaded documents; `version` (optional): print the version;
- `template.json`: the name of the system, `retains_structure` (`yes`, or `no` if it flattens the documents), `proprietary`, and tags;
- the queries file (`queries.sql` by default), one query per line, and the table definition.

The driver installs the system, downloads the dataset (`download-data`), loads it, measuring the load time, runs every query three times, restarting the system and dropping the page cache before the first (cold) run of every query, and writes the result document, `result.json`.

The result files are `<system>/results/<machine>_bluesky_<size>m.json`, with the fields `system`, `version`, `os`, `date`, `machine`, `retains_structure`, `tags`, `dataset_size`, `num_loaded_documents`, `load_time`, `total_size` and `result` (for every query: the cold run and two hot runs, in seconds, `null` for a failed run).
The directories starting with `_files_` hold the sizes of the dataset files themselves, in different compression formats, for comparison of the storage size.

## Running

### On your own machine

```
cd clickhouse
./benchmark.sh 1
```

It installs the system on the current machine, so use a fresh VM for that.
The full dataset takes 125 GB compressed and about 480 GB uncompressed; the 1000m size takes from hours to days, depending on the system.

### In the cloud

`run-benchmark.sh <system> <size>` launches a self-terminating EC2 machine that renders `cloud-init.sh.in`: it clones this repository, runs `<system>/benchmark.sh <size>`, sends `result.json` (with `kind: json-benchmark`) and the logs to the results sink at play.clickhouse.com, and shuts down.

From GitHub Actions:

- "Run a benchmark" (`benchmark-manual.yml`) with `systems: json/<name> ...`, and the inputs `json_sizes` and `json_machines`;
- pull requests that change `json/<name>/` launch that system on the sizes 1, 10 and 100 (add the `json-size:1000` label, or other `json-size:<n>` labels, to choose the sizes), after an approval, as for the main ClickBench;
- "JSONBench weekly" (`json-benchmark-weekly.yml`) runs ClickHouse on every size.

`collect-new-results.sh` reads the results back from the sink: the hourly workflow "Collect JSONBench results" (`json-collect-results.yml`) commits the results of the runs of `main` as an automated pull request, and the results of the runs of a pull request to that pull request.
`generate-results.sh` rebuilds `data.generated.js` for the web page (`index.html`).

## Add a new database

We highly welcome additions of new entries in the benchmark! Please don't hesitate to contribute one.
You don't have to be affiliated with the database engine to contribute to the benchmark.

We welcome all types of databases, including open-source and closed-source, commercial and experimental, distributed or embedded, except one-off customized builds for the benchmark.

Copy one of the directories, for example `clickhouse`, and edit the scripts.
The scripts must run unattended on a fresh Ubuntu machine.
When you send a pull request, the benchmark is run on our machines, and the results are added to your pull request.

For managed services that cannot be installed by a script, describe the procedure in a `README.md` and add the result files yourself (see `hologres`).
