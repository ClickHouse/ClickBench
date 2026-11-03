CREATE TABLE bluesky (
    data JSONB COMPRESSION lz4 NOT NULL
);

CREATE INDEX idx_bluesky
ON bluesky (
    (data ->> 'kind'),
    (data -> 'commit' ->> 'operation'),
    (data -> 'commit' ->> 'collection'),
    (data ->> 'did'),
    (TO_TIMESTAMP((data ->> 'time_us')::BIGINT / 1000000.0))
);
