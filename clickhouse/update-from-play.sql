#!/usr/bin/clickhouse-client --queries-file

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse",
    "date": "{}",
    "machine": "c6a.4xlarge, 500gb gp2",
    "cluster_size": 1,
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
    "machine": "c6a.metal, 500gb gp2",
    "cluster_size": 1,
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
