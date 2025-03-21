# VictoriaLogs

There is no need in creating any table schema - just ingest `hits.json` into VictoriaLogs
via [JSON stream API](https://docs.victoriametrics.com/victorialogs/data-ingestion/#json-stream-api).
See `benchmark.sh` for details.

Queries are translated into [LogsQL](https://docs.victoriametrics.com/victorialogs/logsql/) and are put into `queries.logsql`.
