machine=${machine:=t3a.small}; clickhouse-client --query "

SELECT system FROM (

WITH
    extract(content, 'System: ([^\n]+)') AS system,
    extract(content, 'Machine: ([^\n]+)') AS machine,

    toUInt64OrZero(extract(content, 'Disk usage after: (\d+)')) - toUInt64OrZero(extract(content, 'Disk usage before: (\d+)')) AS disk_space_diff,
    toUInt64OrZero(extract(content, 'Total time: (\d+)')) AS total_time,

    match(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)') ? arraySum(x -> toFloat64(x), extractAll(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)')) : NULL AS load_time,
    match(content, 'Data size: *(\d+)') ? arraySum(x -> toUInt64(x), extractAll(content, 'Data size: *(\d+)')) : NULL AS data_size,

    extractAllGroups(content, '\n *\[([\d\.]+|null),\s*([\d\.]+|null),\s*([\d\.]+|null)\]') AS runtimes,

    load_time IS NOT NULL AND length(runtimes) = 43 AND data_size >= 5000000000
        AND arrayExists(x -> arrayExists(y -> toFloat64OrZero(y) > 1, x), runtimes) AS good

SELECT time, system, machine, total_time, disk_space_diff, load_time, data_size, length(runtimes), runtimes
FROM sink.data
WHERE time >= today() - 5 AND content NOT LIKE 'Cloud-init%' AND good AND machine = '${machine}'
ORDER BY time DESC LIMIT 1 BY system

)

" | while read system; do echo $system; clickhouse-local --query "

WITH file('${system}/results/c6a.4xlarge.json') AS template

SELECT '{
    \"system\": ' || visitParamExtractRaw(template, 'system') || ',
    \"date\": \"' || time::Date || '\",
    \"machine\": \"' || machine || '\",
    \"cluster_size\": 1,
    \"proprietary\": ' || visitParamExtractRaw(template, 'proprietary') || ',
    \"tuned\": ' || visitParamExtractRaw(template, 'tuned') || ',
    \"tags\": ' || visitParamExtractRaw(template, 'tags') || ',
    \"load_time\": ' || load_time || ',
    \"data_size\": ' || data_size || ',
    \"result\": ' || runtimes_formatted || '
}
'

FROM (

WITH
    extract(content, 'System: ([^\n]+)') AS system,
    extract(content, 'Machine: ([^\n]+)') AS machine,

    toUInt64OrZero(extract(content, 'Disk usage after: (\d+)')) - toUInt64OrZero(extract(content, 'Disk usage before: (\d+)')) AS disk_space_diff,
    toUInt64OrZero(extract(content, 'Total time: (\d+)')) AS total_time,

    match(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)') ? arraySum(x -> toFloat64(x), extractAll(content, 'Load time:\s*(?:COPY \d+\n)?(\d+)')) : NULL AS load_time,
    match(content, 'Data size: *(\d+)') ? arraySum(x -> toUInt64(x), extractAll(content, 'Data size: *(\d+)')) : NULL AS data_size,

    extractAllGroups(content, '\n *\[([\d\.]+|null),\s*([\d\.]+|null),\s*([\d\.]+|null)\]') AS runtimes,
    '[\n' || arrayStringConcat(arrayMap(x -> '        [' || arrayStringConcat(arrayMap(v -> v == 'null' ? v : round(v::Float64, 3)::String, x), ', ') || ']', runtimes), ',\n') || '\n]' AS runtimes_formatted,

    load_time IS NOT NULL AND length(runtimes) = 43 AND data_size >= 5000000000
        AND arrayExists(x -> arrayExists(y -> toFloat64OrZero(y) > 1, x), runtimes) AS good

SELECT time, system, machine, total_time, disk_space_diff, load_time, data_size, length(runtimes), runtimes, runtimes_formatted
FROM remote('127.0.0.2', sink.data)
WHERE time >= today() - 2 AND content NOT LIKE 'Cloud-init%' AND good AND machine = '${machine}' AND system = '${system}'
ORDER BY time DESC LIMIT 1
)

INTO OUTFILE '${system}/results/${machine}.json' TRUNCATE
FORMAT RawBLOB

"; done
