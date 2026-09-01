-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
-- JOB schema for Firebolt. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

-- WIDTHS: the canonical JOB schema types 33 of its string columns as
-- character varying(N). Firebolt Core has only TEXT -- no length-limited string
-- type -- so the widths are not expressible here and every string column is TEXT.

CREATE DATABASE IF NOT EXISTS job;

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
    imdb_index    TEXT,
    name_pcode_cf TEXT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum        TEXT)
PRIMARY INDEX id;

CREATE TABLE aka_title (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      TEXT,
    kind_id         INT NOT NULL,
    production_year INT,
    phonetic_code   TEXT,
    episode_of_id   INT,
    season_nr       INT,
    episode_nr      INT,
    note            TEXT,
    md5sum          TEXT)
PRIMARY INDEX id;

CREATE TABLE cast_info (
    id             INT NOT NULL,
    person_id      INT NOT NULL,
    movie_id       INT NOT NULL,
    person_role_id INT,
    note           TEXT,
    nr_order       INT,
    role_id        INT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE char_name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    TEXT,
    imdb_id       INT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum        TEXT)
PRIMARY INDEX id;

CREATE TABLE comp_cast_type (
    id   INT NOT NULL,
    kind TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE company_name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    country_code  TEXT,
    imdb_id       INT,
    name_pcode_nf TEXT,
    name_pcode_sf TEXT,
    md5sum        TEXT)
PRIMARY INDEX id;

CREATE TABLE company_type (
    id   INT NOT NULL,
    kind TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE complete_cast (
    id         INT NOT NULL,
    movie_id   INT,
    subject_id INT NOT NULL,
    status_id  INT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE info_type (
    id   INT NOT NULL,
    info TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE keyword (
    id            INT NOT NULL,
    keyword       TEXT NOT NULL,
    phonetic_code TEXT)
PRIMARY INDEX id;

CREATE TABLE kind_type (
    id   INT NOT NULL,
    kind TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE link_type (
    id   INT NOT NULL,
    link TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE movie_companies (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    company_id      INT NOT NULL,
    company_type_id INT NOT NULL,
    note            TEXT)
PRIMARY INDEX id;

CREATE TABLE movie_info (
    id           INT NOT NULL,
    movie_id     INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
PRIMARY INDEX id;

CREATE TABLE movie_info_idx (
    id           INT NOT NULL,
    movie_id     INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
PRIMARY INDEX id;

CREATE TABLE movie_keyword (
    id         INT NOT NULL,
    movie_id   INT NOT NULL,
    keyword_id INT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE movie_link (
    id              INT NOT NULL,
    movie_id        INT NOT NULL,
    linked_movie_id INT NOT NULL,
    link_type_id    INT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE name (
    id            INT NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    TEXT,
    imdb_id       INT,
    gender        TEXT,
    name_pcode_cf TEXT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum        TEXT)
PRIMARY INDEX id;

CREATE TABLE person_info (
    id           INT NOT NULL,
    person_id    INT NOT NULL,
    info_type_id INT NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT)
PRIMARY INDEX id;

CREATE TABLE role_type (
    id   INT NOT NULL,
    "role" TEXT NOT NULL)
PRIMARY INDEX id;

CREATE TABLE title (
    id              INT NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      TEXT,
    kind_id         INT NOT NULL,
    production_year INT,
    imdb_id         INT,
    phonetic_code   TEXT,
    episode_of_id   INT,
    season_nr       INT,
    episode_nr      INT,
    series_years    TEXT,
    md5sum          TEXT)
PRIMARY INDEX id;

