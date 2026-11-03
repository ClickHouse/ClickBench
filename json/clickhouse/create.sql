CREATE TABLE bluesky
(
    `data` JSON(
        max_dynamic_paths = 0,
        kind LowCardinality(String),
        commit.operation LowCardinality(String),
        commit.collection LowCardinality(String),
        did String,
        time_us UInt64) CODEC(ZSTD(1))
)
ORDER BY (
    data.kind,
    data.commit.operation,
    data.commit.collection,
    data.did,
    fromUnixTimestamp64Micro(data.time_us))
SETTINGS object_serialization_version = 'v3',
         dynamic_serialization_version = 'v3',
         object_shared_data_serialization_version = 'advanced',
         object_shared_data_serialization_version_for_zero_level_parts = 'map_with_buckets';
