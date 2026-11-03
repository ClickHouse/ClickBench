ALTER TABLE bluesky
    ADD COLUMN kind VARCHAR(32) AS (JSON_VALUE(data, '$.kind')) VIRTUAL,
    ADD COLUMN operation VARCHAR(32) AS (JSON_VALUE(data, '$.commit.operation')) VIRTUAL,
    ADD COLUMN collection VARCHAR(320) AS (JSON_VALUE(data, '$.commit.collection')) VIRTUAL,
    ADD COLUMN did VARCHAR(320) AS (JSON_VALUE(data, '$.did')) VIRTUAL,
    ADD COLUMN time_us BIGINT UNSIGNED AS (CAST(JSON_VALUE(data, '$.time_us') AS UNSIGNED)) VIRTUAL,
    ADD INDEX idx_bluesky (kind, operation, collection, did, time_us);
