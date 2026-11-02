CREATE TABLE bluesky (
    kind VARCHAR(100) GENERATED ALWAYS AS (get_json_string(data, '$.kind')) NOT NULL,
    operation VARCHAR(100) GENERATED ALWAYS AS (get_json_string(data, '$.commit.operation')) NULL,
    collection VARCHAR(100) GENERATED ALWAYS AS (get_json_string(data, '$.commit.collection')) NULL,
    did VARCHAR(100) GENERATED ALWAYS AS (get_json_string(data,'$.did')) NOT NULL,
    time DATETIME GENERATED ALWAYS AS (from_microsecond(get_json_bigint(data, '$.time_us'))) NOT NULL,
    `data` variant<'kind': string, 'commit.operation' : string, 'commit.collection' : string, 'did' : string, 'time_us' : bigint, properties("variant_max_subcolumns_count" = "1024")> NOT NULL
)
DUPLICATE KEY (kind, operation, collection, did)
PROPERTIES ("replication_num"="1");
