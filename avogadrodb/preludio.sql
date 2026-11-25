-- Preludio do harness do ClickBench (peca C, 04/10/2026). E a MESMA adaptacao
-- de tipo da entrada oficial do DataFusion (create.sql no commit
-- cb6cabfacee7 do repo ClickHouse/ClickBench: VIEW hits sobre hits_raw com
-- CAST(CAST("EventDate" AS INTEGER) AS DATE)), escrita como CTE porque o motor
-- so le (DDL recusada). No parquet oficial o EventDate e uint16 (dias desde
-- 1970). O CTE sombreia a tabela hits (Postgres: "the WITH query hides any
-- real table of the same name"); o REPLACE mantem a coluna na posicao, como a
-- VIEW do duckdb-parquet. Pinado em
-- crates/avogadrodb-motor/tests/clickbench_preludio.rs.
WITH hits AS (SELECT * REPLACE (CAST(CAST("EventDate" AS INTEGER) AS DATE) AS "EventDate") FROM hits)
