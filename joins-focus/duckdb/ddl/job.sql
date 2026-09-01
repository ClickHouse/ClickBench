-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
-- JOB schema for DuckDB. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

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
    id            INTEGER NOT NULL,
    person_id     INTEGER NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32),
    PRIMARY KEY (id)
);

CREATE TABLE aka_title (
    id              INTEGER NOT NULL,
    movie_id        INTEGER NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      VARCHAR(12),
    kind_id         INTEGER NOT NULL,
    production_year INTEGER,
    phonetic_code   VARCHAR(5),
    episode_of_id   INTEGER,
    season_nr       INTEGER,
    episode_nr      INTEGER,
    note            TEXT,
    md5sum          VARCHAR(32),
    PRIMARY KEY (id)
);

CREATE TABLE cast_info (
    id             INTEGER NOT NULL,
    person_id      INTEGER NOT NULL,
    movie_id       INTEGER NOT NULL,
    person_role_id INTEGER,
    note           TEXT,
    nr_order       INTEGER,
    role_id        INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE char_name (
    id            INTEGER NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    imdb_id       INTEGER,
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32),
    PRIMARY KEY (id)
);

CREATE TABLE comp_cast_type (
    id   INTEGER NOT NULL,
    kind VARCHAR(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE company_name (
    id            INTEGER NOT NULL,
    name          TEXT NOT NULL,
    country_code  VARCHAR(255),
    imdb_id       INTEGER,
    name_pcode_nf VARCHAR(5),
    name_pcode_sf VARCHAR(5),
    md5sum        VARCHAR(32),
    PRIMARY KEY (id)
);

CREATE TABLE company_type (
    id   INTEGER NOT NULL,
    kind VARCHAR(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE complete_cast (
    id         INTEGER NOT NULL,
    movie_id   INTEGER,
    subject_id INTEGER NOT NULL,
    status_id  INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE info_type (
    id   INTEGER NOT NULL,
    info VARCHAR(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE keyword (
    id            INTEGER NOT NULL,
    keyword       TEXT NOT NULL,
    phonetic_code VARCHAR(5),
    PRIMARY KEY (id)
);

CREATE TABLE kind_type (
    id   INTEGER NOT NULL,
    kind VARCHAR(15) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE link_type (
    id   INTEGER NOT NULL,
    link VARCHAR(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_companies (
    id              INTEGER NOT NULL,
    movie_id        INTEGER NOT NULL,
    company_id      INTEGER NOT NULL,
    company_type_id INTEGER NOT NULL,
    note            TEXT,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info (
    id           INTEGER NOT NULL,
    movie_id     INTEGER NOT NULL,
    info_type_id INTEGER NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info_idx (
    id           INTEGER NOT NULL,
    movie_id     INTEGER NOT NULL,
    info_type_id INTEGER NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT,
    PRIMARY KEY (id)
);

CREATE TABLE movie_keyword (
    id         INTEGER NOT NULL,
    movie_id   INTEGER NOT NULL,
    keyword_id INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_link (
    id              INTEGER NOT NULL,
    movie_id        INTEGER NOT NULL,
    linked_movie_id INTEGER NOT NULL,
    link_type_id    INTEGER NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE name (
    id            INTEGER NOT NULL,
    name          TEXT NOT NULL,
    imdb_index    VARCHAR(12),
    imdb_id       INTEGER,
    gender        VARCHAR(1),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum        VARCHAR(32),
    PRIMARY KEY (id)
);

CREATE TABLE person_info (
    id           INTEGER NOT NULL,
    person_id    INTEGER NOT NULL,
    info_type_id INTEGER NOT NULL,
    info         TEXT NOT NULL,
    note         TEXT,
    PRIMARY KEY (id)
);

CREATE TABLE role_type (
    id   INTEGER NOT NULL,
    "role" VARCHAR(32) NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE title (
    id              INTEGER NOT NULL,
    title           TEXT NOT NULL,
    imdb_index      VARCHAR(12),
    kind_id         INTEGER NOT NULL,
    production_year INTEGER,
    imdb_id         INTEGER,
    phonetic_code   VARCHAR(5),
    episode_of_id   INTEGER,
    season_nr       INTEGER,
    episode_nr      INTEGER,
    series_years    VARCHAR(49),
    md5sum          VARCHAR(32),
    PRIMARY KEY (id)
);

