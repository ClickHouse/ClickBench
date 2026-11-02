CREATE TABLE bluesky (
    `id` BIGINT AUTO_INCREMENT,
    `data` JSON NOT NULL COMMENT "Primary JSON object, optimized for field access using FlatJSON",

    sort_key VARBINARY AS encode_sort_key(
        get_json_string(data, 'kind'),
        get_json_string(data, 'commit.operation'),
        get_json_string(data, 'commit.collection'),
        get_json_string(data, 'did')
    )
)
ORDER BY (sort_key);
