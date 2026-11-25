CREATE INDEX idx_bluesky
ON bluesky (
    (data ->> '$.kind'),
    (data ->> '$.commit.operation'),
    (data ->> '$.commit.collection'),
    (data ->> '$.did'),
    (data ->> '$.time_us')
);
ANALYZE;
