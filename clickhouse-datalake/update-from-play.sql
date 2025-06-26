#!/usr/bin/clickhouse-client --queries-file

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse (data lake, partitioned)",
    "date": "{}",
    "machine": "c6a.4xlarge, 500gb gp2",
    "cluster_size": 1,
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "embedded", "stateless", "ClickHouse derivative"],
    "load_time": 0,
    "data_size": 14737666736,
    "result": [
{}
    ]
}}
$$, time::Date, replaceRegexpOne(stateless_results[1], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse-datalake' AND suite_machine[2] = 'c6a.4xlarge'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.4xlarge.partitioned.json' TRUNCATE
FORMAT Raw;

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse (data lake, partitioned)",
    "date": "{}",
    "machine": "c6a.metal, 500gb gp2",
    "cluster_size": 1,
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "embedded", "stateless", "ClickHouse derivative"],
    "load_time": 0,
    "data_size": 14737666736,
    "result": [
{}
    ]
}}
$$, time::Date, replaceRegexpOne(stateless_results[1], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse-datalake' AND suite_machine[2] = 'c6a.metal'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.metal.partitioned.json' TRUNCATE
FORMAT Raw;

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse (data lake, single)",
    "date": "{}",
    "machine": "c6a.4xlarge, 500gb gp2",
    "cluster_size": 1,
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "embedded", "stateless", "ClickHouse derivative"],
    "load_time": 0,
    "data_size": 14737666736,
    "result": [
{}
    ]
}}
$$, time::Date, replaceRegexpOne(stateless_results[2], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse-datalake' AND suite_machine[2] = 'c6a.4xlarge'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.4xlarge.single.json' TRUNCATE
FORMAT Raw;

WITH
    extractGroups(content, '\nhttps://raw\.githubusercontent\.com/ClickHouse/ClickBench/main/([\w\-]+)/\n(\w+\.(?:\dxlarge|metal))') AS suite_machine,
    extractGroups(content, '\n([\d\.]+)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)(\d+)') AS time_results_size,
    extractAll(content, '(?:Single:|Partitioned:)\n((?:\[[\d\.]+, [\d\.]+, [\d\.]+\],\n)+)') AS stateless_results
SELECT format(
$${{
    "system": "ClickHouse (data lake, single)",
    "date": "{}",
    "machine": "c6a.metal, 500gb gp2",
    "cluster_size": 1,
    "tuned": "no",
    "comment": "",
    "tags": ["C++", "column-oriented", "embedded", "stateless", "ClickHouse derivative"],
    "load_time": 0,
    "data_size": 14737666736,
    "result": [
{}
    ]
}}
$$, time::Date, replaceRegexpOne(stateless_results[2], ',\n$', '')) AS res
FROM sink.data
WHERE suite_machine[1] = 'clickhouse-datalake' AND suite_machine[2] = 'c6a.metal'
ORDER BY time DESC LIMIT 1
INTO OUTFILE 'results/c6a.metal.single.json' TRUNCATE
FORMAT Raw;
