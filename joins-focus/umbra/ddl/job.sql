-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
-- JOB schema for Umbra. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE SCHEMA IF NOT EXISTS job;
-- Selected once for the whole script: the runner feeds this file to a single
-- psql session, so every table below can be named unqualified.
SET search_path TO job;

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
    id            integer NOT NULL,
    person_id     integer NOT NULL,
    name          text NOT NULL,
    imdb_index    varchar(12),
    name_pcode_cf varchar(5),
    name_pcode_nf varchar(5),
    surname_pcode varchar(5),
    md5sum        varchar(32),
    PRIMARY KEY (id)
);

CREATE TABLE aka_title (
    id              integer NOT NULL,
    movie_id        integer NOT NULL,
    title           text NOT NULL,
    imdb_index      varchar(12),
    kind_id         integer NOT NULL,
    production_year integer,
    phonetic_code   varchar(5),
    episode_of_id   integer,
    season_nr       integer,
    episode_nr      integer,
    note            text,
    md5sum          varchar(32),
    PRIMARY KEY (id)
);

CREATE TABLE cast_info (
    id             integer NOT NULL,
    person_id      integer NOT NULL,
    movie_id       integer NOT NULL,
    person_role_id integer,
    note           text,
    nr_order       integer,
    role_id        integer NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE char_name (
    id            integer NOT NULL,
    name          text NOT NULL,
    imdb_index    varchar(12),
    imdb_id       integer,
    name_pcode_nf varchar(5),
    surname_pcode varchar(5),
    md5sum        varchar(32),
    PRIMARY KEY (id)
);

CREATE TABLE comp_cast_type (
    id   integer NOT NULL,
    kind varchar(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE company_name (
    id            integer NOT NULL,
    name          text NOT NULL,
    country_code  varchar(255),
    imdb_id       integer,
    name_pcode_nf varchar(5),
    name_pcode_sf varchar(5),
    md5sum        varchar(32),
    PRIMARY KEY (id)
);

CREATE TABLE company_type (
    id   integer NOT NULL,
    kind varchar(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE complete_cast (
    id         integer NOT NULL,
    movie_id   integer,
    subject_id integer NOT NULL,
    status_id  integer NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE info_type (
    id   integer NOT NULL,
    info varchar(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE keyword (
    id            integer NOT NULL,
    keyword       text NOT NULL,
    phonetic_code varchar(5),
    PRIMARY KEY (id)
);

CREATE TABLE kind_type (
    id   integer NOT NULL,
    kind varchar(15) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE link_type (
    id   integer NOT NULL,
    link varchar(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_companies (
    id              integer NOT NULL,
    movie_id        integer NOT NULL,
    company_id      integer NOT NULL,
    company_type_id integer NOT NULL,
    note            text,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info (
    id           integer NOT NULL,
    movie_id     integer NOT NULL,
    info_type_id integer NOT NULL,
    info         text NOT NULL,
    note         text,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info_idx (
    id           integer NOT NULL,
    movie_id     integer NOT NULL,
    info_type_id integer NOT NULL,
    info         text NOT NULL,
    note         text,
    PRIMARY KEY (id)
);

CREATE TABLE movie_keyword (
    id         integer NOT NULL,
    movie_id   integer NOT NULL,
    keyword_id integer NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_link (
    id              integer NOT NULL,
    movie_id        integer NOT NULL,
    linked_movie_id integer NOT NULL,
    link_type_id    integer NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE name (
    id            integer NOT NULL,
    name          text NOT NULL,
    imdb_index    varchar(12),
    imdb_id       integer,
    gender        varchar(1),
    name_pcode_cf varchar(5),
    name_pcode_nf varchar(5),
    surname_pcode varchar(5),
    md5sum        varchar(32),
    PRIMARY KEY (id)
);

CREATE TABLE person_info (
    id           integer NOT NULL,
    person_id    integer NOT NULL,
    info_type_id integer NOT NULL,
    info         text NOT NULL,
    note         text,
    PRIMARY KEY (id)
);

CREATE TABLE role_type (
    id   integer NOT NULL,
    "role" varchar(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE title (
    id              integer NOT NULL,
    title           text NOT NULL,
    imdb_index      varchar(12),
    kind_id         integer NOT NULL,
    production_year integer,
    imdb_id         integer,
    phonetic_code   varchar(5),
    episode_of_id   integer,
    season_nr       integer,
    episode_nr      integer,
    series_years    varchar(49),
    md5sum          varchar(32),
    PRIMARY KEY (id)
);

