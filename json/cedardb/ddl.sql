-- As the PostgreSQL entry, but without its expression index: CedarDB supports
-- only indexes on columns, not on expressions
-- (https://cedardb.com/docs/references/objects/indexes/).
CREATE TABLE bluesky (
    data JSONB NOT NULL
);
