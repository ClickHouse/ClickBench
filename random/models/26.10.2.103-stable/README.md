The model of clickhouse-obfuscator for ClickHouse 26.10.2.103-stable, trained by
`random/lib/train-model.sh` on 2000364 rows of the hits dataset (a sample chosen
by `cityHash64(WatchID, UserID, EventTime) % 1000000 < 20000`).
`model.bin.zst` is the uncompressed model file, compressed with `zstd -9`
(sha256 of the uncompressed file: 844484def2702057f0d35908c63e2292702e533b606942cc8524d157ea68f37a).
