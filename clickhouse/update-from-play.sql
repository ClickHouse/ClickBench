#!/usr/bin/clickhouse-client --queries-file

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse",
    "date": "{}",
    "machine": "c6a.4xlarge",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "ClickHouse derivative"],
    "load_time": {},
    "data_size": {},
    "result": [
{}
    ]
}}
$$, time::Date, time_results_size[1], time_results_size[3], replaceRegexpOne(time_results_size[2], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse' AND suite_machine[2] = 'c6a.4xlarge'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.4xlarge.json' TRUNCATE
FORMAT Raw;

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse",
    "date": "{}",
    "machine": "c6a.metal",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "ClickHouse derivative"],
    "load_time": {},
    "data_size": {},
    "result": [
{}
    ]
}}
$$, time::Date, time_results_size[1], time_results_size[3], replaceRegexpOne(time_results_size[2], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse' AND suite_machine[2] = 'c6a.metal'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.metal.json' TRUNCATE
FORMAT Raw;

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractAllGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS all_time_results_size,
    all_time_results_size[1] AS regular,
    all_time_results_size[2] AS tuned,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse (tuned, memory)",
    "date": "{}",
    "machine": "c6a.metal",
    "cluster_size": 1,
    "proprietary": "no",
    "tuned": "yes",
    "comment": "",
    "tags": ["C++", "column-oriented", "ClickHouse derivative"],
    "load_time": {},
    "data_size": {},
    "result": [
{}
    ]
}}
$$, time::Date, tuned[1], tuned[3], replaceRegexpOne(tuned[2], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse' AND suite_machine[2] = 'c6a.metal'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.metal.tuned.memory.json' TRUNCATE
FORMAT Raw;
