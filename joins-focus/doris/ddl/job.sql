-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
-- JOB schema for Doris. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE DATABASE IF NOT EXISTS job;
-- Selected once for the whole script: the runner feeds this file to a single
-- mysql session, so every table below can be named unqualified.
USE job;

DROP TABLE IF EXISTS title;
DROP TABLE IF EXISTS role_type;
DROP TABLE IF EXISTS person_info;
DROP TABLE IF EXISTS name;
DROP TABLE IF EXISTS movie_link;
DROP TABLE IF EXISTS movie_keyword;
DROP TABLE IF EXISTS movie_info_idx;
DROP TABLE IF EXISTS movie_info;
DROP TABLE IF EXISTS movie_companies;
DROP TABLE IF EXISTS link_type;
DROP TABLE IF EXISTS kind_type;
DROP TABLE IF EXISTS keyword;
DROP TABLE IF EXISTS info_type;
DROP TABLE IF EXISTS complete_cast;
DROP TABLE IF EXISTS company_type;
DROP TABLE IF EXISTS company_name;
DROP TABLE IF EXISTS comp_cast_type;
DROP TABLE IF EXISTS char_name;
DROP TABLE IF EXISTS cast_info;
DROP TABLE IF EXISTS aka_title;
DROP TABLE IF EXISTS aka_name;

CREATE TABLE aka_name (
    id            INT NOT NULL,
    person_id     INT NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE aka_title (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      VARCHAR(12),
    kind_id         INT NOT NULL,
    production_year INT,
    phonetic_code   VARCHAR(5),
    episode_of_id   INT,
    season_nr       INT,
    episode_nr      INT,
    note            TEXT,
    md5sum          VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE cast_info (
    id             INT NOT NULL,
    person_id      INT NOT NULL,
    movie_id       INT NOT NULL,
    person_role_id INT,
    note           TEXT,
    nr_order       INT,
    role_id        INT NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE char_name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    imdb_id       INT,
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE comp_cast_type (
    id   INT NOT NULL,
    kind VARCHAR(32) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE company_name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    country_code  VARCHAR(255),
    imdb_id       INT,
    name_pcode_nf VARCHAR(5),
    name_pcode_sf VARCHAR(5),
    md5sum        VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE company_type (
    id   INT NOT NULL,
    kind VARCHAR(32) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE complete_cast (
    id         INT NOT NULL,
    movie_id   INT,
    subject_id INT NOT NULL,
    status_id  INT NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE info_type (
    id   INT NOT NULL,
    info VARCHAR(32) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE keyword (
    id            INT NOT NULL,
    keyword       TEXT NOT NULL,
    phonetic_code VARCHAR(5))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE kind_type (
    id   INT NOT NULL,
    kind VARCHAR(15) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE link_type (
    id   INT NOT NULL,
    link VARCHAR(32) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE movie_companies (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    company_id      INT NOT NULL,
    company_type_id INT NOT NULL,
    note            TEXT)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE movie_info (
    id           INT NOT NULL,
    movie_id     INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE movie_info_idx (
    id           INT NOT NULL,
    movie_id     INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE movie_keyword (
    id         INT NOT NULL,
    movie_id   INT NOT NULL,
    keyword_id INT NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE movie_link (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    linked_movie_id INT NOT NULL,
    link_type_id    INT NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    imdb_id       INT,
    gender        VARCHAR(1),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE person_info (
    id           INT NOT NULL,
    person_id    INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE role_type (
    id   INT NOT NULL,
    `role` VARCHAR(32) NOT NULL)
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

CREATE TABLE title (
    id              INT NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      VARCHAR(12),
    kind_id         INT NOT NULL,
    production_year INT,
    imdb_id         INT,
    phonetic_code   VARCHAR(5),
    episode_of_id   INT,
    season_nr       INT,
    episode_nr      INT,
    series_years    VARCHAR(49),
    md5sum          VARCHAR(32))
DUPLICATE KEY(id)
PROPERTIES('replication_num'='1');

