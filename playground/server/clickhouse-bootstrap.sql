-- ClickHouse bootstrap for the playground.
--
-- Run as the default user on every server startup. Idempotent: CREATE
-- IF NOT EXISTS / CREATE OR REPLACE / ALTER USER ... IDENTIFIED.
--
-- Parameters (passed via HTTP ?param_db=... etc. or substituted in
-- Python for the user-creation statements where CH doesn't accept
-- query parameters):
--   {db:Identifier}        target database name
--   {writer_pw:String}     freshly-rotated password for the writer user
--   {writer_host:String}   IP the writer must connect from (the playground
--                          server's public IP, as seen by CH Cloud)
--   {reader_pw:String}     freshly-rotated password for the reader user

-- ===========================================================================
-- Schema
-- ===========================================================================

CREATE DATABASE IF NOT EXISTS {db:Identifier};

-- Request log + shared queries (same table).
-- ORDER BY ts so recent rows cluster (chronological retention / TTL friendly).
-- The `id` is a random 64-bit handle the API returns to the client; an
-- INDEX projection on `id` (ClickHouse 26.1 syntax) gives a fast
-- equality lookup without sorting the main part by id.
CREATE TABLE IF NOT EXISTS {db:Identifier}.requests (
    id                UInt64,
    ts                DateTime64(6) DEFAULT now64(6),
    client_addr       String,
    user_agent        String,
    system            LowCardinality(String),
    query             String,
    output            String,
    output_bytes      UInt64,
    output_truncated  UInt8,
    query_time        Nullable(Float64),
    wall_time         Float64,
    status            UInt16,
    error             String,
    PROJECTION by_id INDEX id TYPE basic
) ENGINE = MergeTree ORDER BY ts;

-- Operational events (vm boot, oom-kick, watchdog teardown, ...).
CREATE TABLE IF NOT EXISTS {db:Identifier}.events (
    ts      DateTime64(6) DEFAULT now64(6),
    system  LowCardinality(String),
    kind    LowCardinality(String),
    detail  String
) ENGINE = MergeTree ORDER BY ts;

-- Parameterized view for the read-only public user. SQL SECURITY DEFINER
-- runs the SELECT as the view's owner (the default user), so the reader
-- doesn't need a direct grant on `requests` — just SELECT on the view.
-- The id projection makes this an O(log n) lookup even when the table
-- has billions of rows.
CREATE OR REPLACE VIEW {db:Identifier}.request_by_id
DEFINER = default
SQL SECURITY DEFINER
AS SELECT * FROM {db:Identifier}.requests
   WHERE id = {q_id:UInt64}
   LIMIT 1;
