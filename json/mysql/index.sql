CREATE INDEX idx_bluesky
ON bluesky (
    (CAST(data ->> '$.kind' AS CHAR(32)) COLLATE utf8mb4_bin),
    (CAST(data ->> '$.commit.operation' AS CHAR(32)) COLLATE utf8mb4_bin),
    (CAST(data ->> '$.commit.collection' AS CHAR(320)) COLLATE utf8mb4_bin),
    (CAST(data ->> '$.did' AS CHAR(320)) COLLATE utf8mb4_bin),
    (CAST(data ->> '$.time_us' AS UNSIGNED))
);
