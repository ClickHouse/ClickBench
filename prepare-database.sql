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
    -- Sustained-throughput test that runs after the cold/warm sweep.
    -- concurrent_qps is NULL when the engine died and the watchdog never
    -- got it back up to serve a single query; concurrent_error_ratio is
    -- NULL only if zero queries were attempted (shouldn't happen unless
    -- BENCH_CONCURRENT_DURATION was set to 0).
    concurrent_qps Nullable(Float64),
    concurrent_error_ratio Nullable(Float64),
    -- Median time in seconds for a cold system to become ready with the data
    -- loaded (lib/benchmark-common.sh bench_startup_time). NULL when it could
    -- not be measured, and for logs predating the measurement.
    startup_time Nullable(Float64),
    -- The pull request number when the run was launched by the PR workflow;
    -- 0 for runs of main and for logs predating this column.
    clickbench_pr UInt32,
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

    -- Concurrent QPS test (lib/benchmark-common.sh bench_concurrent_qps).
    -- The bench emits "Concurrent QPS: <num|null>" and
    -- "Concurrent error ratio: <num|null>" at the end of the log.
    -- toFloat64OrNull treats the literal "null" string as NULL, so
    -- "Concurrent QPS: null" (engine never recovered during the window)
    -- ends up as a NULL in the column.
    toFloat64OrNull(extract(content, 'Concurrent QPS: ([0-9.]+|null)')) AS concurrent_qps,
    toFloat64OrNull(extract(content, 'Concurrent error ratio: ([0-9.]+|null)')) AS concurrent_error_ratio,
    toFloat64OrNull(extract(content, 'Startup time: ([0-9.]+|null)')) AS startup_time,

    -- \d* rather than \d+: the header line is 'ClickBench PR: ' with no number
    -- for runs of main, and the empty match there stops the search before any
    -- 'ClickBench PR: <number>' that may occur later in untrusted bench output.
    toUInt32OrZero(extract(content, 'ClickBench PR: (\d*)')) AS clickbench_pr,

    load_time IS NOT NULL AND length(runtimes) = 43 AND data_size >= 5000000000
        AND arrayExists(x -> arrayExists(y -> toFloat64OrZero(y) > 0.1, x), runtimes) AS good

SELECT time, system, machine, system_name, proprietary, tuned, tags, total_time, disk_space_diff, load_time, data_size, length(runtimes) AS num_results, runtimes, runtimes_formatted,
    concurrent_qps, concurrent_error_ratio, startup_time, clickbench_pr,
'{
    "system": "' || system_name || '",
    "date": "' || time::Date || '",
    "machine": "' || machine || '",
    "cluster_size": 1,
    "proprietary": "' || proprietary || '",
    "hardware": "cpu",
    "tuned": "' || tuned || '",
    "tags": ' || tags || ',
    "load_time": ' || load_time || ',
    "data_size": ' || data_size || ',
    "concurrent_qps": ' || ifNull(toString(concurrent_qps), 'null') || ',
    "concurrent_error_ratio": ' || ifNull(toString(concurrent_error_ratio), 'null') || ',
    "startup_time": ' || ifNull(toString(startup_time), 'null') || ',
    "result": ' || runtimes_formatted || '
}
' AS output
FROM sink.data
WHERE time >= yesterday() AND content NOT LIKE 'Cloud-init%' AND good;

-- Read-only user for the results collection automation
-- (collect-new-results.py). The password is in the CLICKBENCH_DB_PASSWORD
-- GitHub secret of ClickHouse/ClickBench.
CREATE USER clickbench IDENTIFIED WITH sha256_password BY '<password>'
SETTINGS readonly = 1;

GRANT SELECT ON sink.data TO clickbench;
GRANT SELECT ON sink.results TO clickbench;

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

-- Live logs (lib/live-log.py, live.html): the benchmark machines stream the
-- output of cloud-init.sh into this table as it goes, about one insert per
-- second, a row per line, and live.html follows a run with a streaming query:
--     SELECT ... FROM sink.logs STREAM WHERE run_id = ... AND line_number > ...
-- The streaming query (`STREAM`) needs the block number and offset columns
-- and their min-max indices. It returns the rows in the order of the inserts,
-- and `line_number` lets the reader resume after a reconnect without gaps and
-- skip the duplicates of retried inserts. The logs are kept for a month; the
-- complete log of every run is in sink.data anyway.
CREATE TABLE sink.logs
(
    run_id UUID,
    system LowCardinality(String),
    machine LowCardinality(String),
    line_number UInt64,
    time DateTime64(3),
    line String CODEC(ZSTD(3)),
    -- The last row of a run that ended normally, with an empty line.
    eof Bool
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/sink/logs/{shard}', '{replica}')
ORDER BY (run_id, line_number)
TTL toDateTime(time) + INTERVAL 30 DAY
SETTINGS
    enable_block_number_column = 1,
    enable_block_offset_column = 1,
    add_minmax_index_for_block_number_column = 1,
    add_minmax_index_for_block_offset_column = 1,
    part_minmax_index_columns = 'with_block_number_offset';

-- The writer: lib/live-log.py on the benchmark machines. Async inserts batch the
-- rows of all the machines running at the same time into fewer parts.
CREATE USER sink_logs IDENTIFIED WITH no_password
DEFAULT DATABASE sink
SETTINGS
    async_insert = 1 READONLY,
    wait_for_async_insert = 1 READONLY,
    max_query_size = '1M' READONLY;

-- One insert per second, with room for retries, and the output of builds from source.
CREATE QUOTA sink_logs
KEYED BY ip_address
FOR RANDOMIZED INTERVAL 1 MINUTE MAX query_inserts = 200, written_bytes = 50000000,
FOR RANDOMIZED INTERVAL 1 DAY MAX query_inserts = 200000, written_bytes = 1000000000
TO sink_logs;

GRANT INSERT ON sink.logs TO sink_logs;

-- The reader: live.html. Unlike `play`, it has the streaming queries enabled,
-- and the queries can run for an hour (the page reconnects after that). The
-- settings are fixed by readonly = 1.
-- A streaming query that waits for new rows does not notice that the client
-- has gone, and does not check max_execution_time either, until the table gets
-- a new part (then cancel_http_readonly_queries_on_client_close kills it), so
-- the number of concurrent queries is limited.
CREATE USER live_logs IDENTIFIED WITH no_password
DEFAULT DATABASE sink
SETTINGS
    readonly = 1,
    add_http_cors_header = 1,
    -- Browsers always ask for compression, and the compressed response is sent
    -- in large chunks, which holds back the new lines of a streaming query.
    enable_http_compression = 0,
    enable_analyzer = 1,
    enable_streaming_queries = 1,
    use_skip_indexes_on_data_read = 0,
    max_execution_time = 3600,
    max_result_bytes = 1000000000,
    cancel_http_readonly_queries_on_client_close = 1,
    max_concurrent_queries_for_user = 200;

CREATE QUOTA live_logs
KEYED BY ip_address
FOR RANDOMIZED INTERVAL 1 MINUTE MAX queries = 60
TO live_logs;

GRANT SELECT ON sink.logs TO live_logs;

-- All the result files of the repository, <system>/results/<date>/<name>.json,
-- for the history view of the website (index.html) and for ad-hoc queries.
-- A row per file, with the fields of the JSON in columns, including the failed runs ({"error": "..."}) and the
-- entries tagged "historical". The content is replaced by upload-history.py
-- on every change of the results, atomically: it fills
-- clickbench.results_staging and moves its contents over with
-- ALTER TABLE REPLACE PARTITION, so the two tables must have the same
-- structure, sorting key and partitioning.
--
-- The staging table is not replicated: it is filled and moved over within one
-- connection, on one replica, and the other replicas fetch the new parts of
-- clickbench.results from it. But it must exist on every replica, as any of
-- them can get the connection - as well as the database and the user.
CREATE DATABASE clickbench;

CREATE TABLE clickbench.results
(
    -- The path of the file in the repository and the git blob id of its content.
    source String,
    blob String,
    -- An entry of the website, one line in the report, is a pair (directory, name),
    -- e.g. ('clickhouse', 'c6a.4xlarge.json'), and its history are the files in
    -- different dated directories: clickhouse/results/20250101/c6a.4xlarge.json, ...
    directory LowCardinality(String),
    name LowCardinality(String),
    -- From the name of the dated directory.
    file_date Date,

    -- The fields of the JSON, where present. The date falls back to file_date.
    system LowCardinality(String),
    date Date,
    machine LowCardinality(String),
    -- A number, or a string for some of the cloud services.
    cluster_size LowCardinality(String),
    proprietary LowCardinality(String),
    hardware LowCardinality(String),
    tuned LowCardinality(String),
    tags Array(LowCardinality(String)),
    comment String,
    load_time Nullable(Float64),
    data_size Nullable(UInt64),
    concurrent_qps Nullable(Float64),
    concurrent_error_ratio Nullable(Float64),
    -- [cold, hot, hot] runtimes in seconds for every query, NULL for failed queries.
    result Array(Array(Nullable(Float64))),
    error String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/clickbench/results/{shard}', '{replica}')
ORDER BY (directory, name, file_date);

CREATE TABLE clickbench.results_staging AS clickbench.results
ENGINE = MergeTree
ORDER BY (directory, name, file_date);

-- The website reads the history as the public `play` user.
GRANT SELECT ON clickbench.results TO play;

-- The user for upload-history.py (.github/workflows/upload-history.yml).
-- The password is in the CLICKBENCH_UPLOAD_PASSWORD GitHub secret of
-- ClickHouse/ClickBench. REPLACE PARTITION needs SELECT on the source table,
-- and ALTER DELETE and INSERT on the destination.
CREATE USER clickbench_upload IDENTIFIED WITH sha256_password BY '<password>';

GRANT SELECT, INSERT, TRUNCATE ON clickbench.results_staging TO clickbench_upload;
GRANT SELECT, INSERT, ALTER DELETE ON clickbench.results TO clickbench_upload;
