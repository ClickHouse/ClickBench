CREATE DATABASE sink;

CREATE TABLE sink.data
(
    time DateTime MATERIALIZED now(),
    content String,
    CONSTRAINT length CHECK length(content) < 1024 * 1024
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/sink/data/{shard}', '{replica}') ORDER BY (time);

CREATE TABLE sink.results
(
    time DateTime,
    system String,
    machine String,
    system_name String,
    proprietary String,
    tuned String,
    tags String,
    total_time UInt64,
    disk_space_diff UInt64,
    load_time Float64,
    data_size UInt64,
    num_results UInt64,
    runtimes String,
    runtimes_formatted String,
    output String,
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/sink/results/{shard}', '{replica}') ORDER BY (time);

CREATE MATERIALIZED VIEW sink.parser TO sink.results AS
WITH
    extract(content, 'System: ([^\n]+)') AS system,
    extract(content, 'Machine: ([^\n]+)') AS machine,
    extract(content, 'System name: ([^\n]+)') AS system_name,
    extract(content, 'Proprietary: ([^\n]+)') AS proprietary,
    extract(content, 'Tuned: ([^\n]+)') AS tuned,
    extract(content, 'Tags: ([^\n]+)') AS tags,

    toUInt64OrZero(extract(content, 'Disk usage after: (\d+)')) - toUInt64OrZero(extract(content, 'Disk usage before: (\d+)')) AS disk_space_diff,
    toUInt64OrZero(extract(content, 'Total time: (\d+)')) AS total_time,

    match(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)') ? arraySum(x -> toFloat64(x), extractAll(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)')) : NULL AS load_time,
    match(content, 'Data size: *(\d+)') ? arraySum(x -> toUInt64(x), extractAll(content, 'Data size: *(\d+)')) : NULL AS data_size,

    extractAllGroups(content, '\n *\[([\d\.]+|null),\s*([\d\.]+|null),\s*([\d\.]+|null)\]') AS runtimes,
    '[\n' || arrayStringConcat(arrayMap(x -> '        [' || arrayStringConcat(arrayMap(v -> v == 'null' ? v : round(v::Float64, 3)::String, x), ', ') || ']', runtimes), ',\n') || '\n]' AS runtimes_formatted,

    load_time IS NOT NULL AND length(runtimes) = 43 AND data_size >= 5000000000
        AND arrayExists(x -> arrayExists(y -> toFloat64OrZero(y) > 1, x), runtimes) AS good

SELECT time, system, machine, system_name, proprietary, tuned, tags, total_time, disk_space_diff, load_time, data_size, length(runtimes) AS num_results, runtimes, runtimes_formatted,
'{
    "system": "' || system_name || '",
    "date": "' || time::Date || '",
    "machine": "' || machine || '",
    "cluster_size": 1,
    "proprietary": "' || proprietary || '",
    "tuned": "' || tuned || '",
    "tags": ' || tags || ',
    "load_time": ' || load_time || ',
    "data_size": ' || data_size || ',
    "result": ' || runtimes_formatted || '
}
' AS output
FROM sink.data
WHERE time >= yesterday() AND content NOT LIKE 'Cloud-init%' AND good;

CREATE USER sink IDENTIFIED WITH no_password
DEFAULT DATABASE sink
SETTINGS
    async_insert = 1 READONLY,
    max_query_size = '10M' READONLY;

CREATE QUOTA sink
KEYED BY ip_address
FOR RANDOMIZED INTERVAL 1 MINUTE MAX query_inserts = 10, written_bytes = 10000000,
FOR RANDOMIZED INTERVAL 1 HOUR MAX query_inserts = 50, written_bytes = 50000000,
FOR RANDOMIZED INTERVAL 1 DAY MAX query_inserts = 500, written_bytes = 200000000
TO sink;

GRANT INSERT ON sink.data TO sink;
GRANT SELECT ON sink.data TO sink;
