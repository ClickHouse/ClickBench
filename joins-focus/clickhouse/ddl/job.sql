-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
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

-- WIDTHS: the canonical JOB schema types 33 of its string columns as
-- character varying(N) (imdb_index 12, the pcode fields 5, md5sum 32, gender 1,
-- series_years 49, country_code 255, kind 15/32). ClickHouse has no
-- length-limited string type: String is unbounded and FixedString(N) PADS to N,
-- which would change the data. So the widths are not expressible here and every
-- string column is String. The 16 genuinely unbounded `text` columns match.

CREATE TABLE aka_name (
    id               Int32 NOT NULL,
    person_id        Int32 NOT NULL,
    name             String NOT NULL,
    imdb_index       String,
    name_pcode_cf    String,
    name_pcode_nf    String,
    surname_pcode    String,
    md5sum           String,
    PRIMARY KEY (id)
);

CREATE TABLE aka_title (
    id                 Int32 NOT NULL,
    movie_id           Int32 NOT NULL,
    title              String NOT NULL,
    imdb_index         String,
    kind_id            Int32 NOT NULL,
    production_year    Int32,
    phonetic_code      String,
    episode_of_id      Int32,
    season_nr          Int32,
    episode_nr         Int32,
    note               String,
    md5sum             String,
    PRIMARY KEY (id)
);

CREATE TABLE cast_info (
    id                Int32 NOT NULL,
    person_id         Int32 NOT NULL,
    movie_id          Int32 NOT NULL,
    person_role_id    Int32,
    note              String,
    nr_order          Int32,
    role_id           Int32 NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE char_name (
    id               Int32 NOT NULL,
    name             String NOT NULL,
    imdb_index       String,
    imdb_id          Int32,
    name_pcode_nf    String,
    surname_pcode    String,
    md5sum           String,
    PRIMARY KEY (id)
);

CREATE TABLE comp_cast_type (
    id      Int32 NOT NULL,
    kind    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE company_name (
    id               Int32 NOT NULL,
    name             String NOT NULL,
    country_code     String,
    imdb_id          Int32,
    name_pcode_nf    String,
    name_pcode_sf    String,
    md5sum           String,
    PRIMARY KEY (id)
);

CREATE TABLE company_type (
    id      Int32 NOT NULL,
    kind    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE complete_cast (
    id            Int32 NOT NULL,
    movie_id      Int32,
    subject_id    Int32 NOT NULL,
    status_id     Int32 NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE info_type (
    id      Int32 NOT NULL,
    info    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE keyword (
    id               Int32 NOT NULL,
    keyword          String NOT NULL,
    phonetic_code    String,
    PRIMARY KEY (id)
);

CREATE TABLE kind_type (
    id      Int32 NOT NULL,
    kind    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE link_type (
    id      Int32 NOT NULL,
    link    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_companies (
    id                 Int32 NOT NULL,
    movie_id           Int32 NOT NULL,
    company_id         Int32 NOT NULL,
    company_type_id    Int32 NOT NULL,
    note               String,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info (
    id              Int32 NOT NULL,
    movie_id        Int32 NOT NULL,
    info_type_id    Int32 NOT NULL,
    info            String NOT NULL,
    note            String,
    PRIMARY KEY (id)
);

CREATE TABLE movie_info_idx (
    id              Int32 NOT NULL,
    movie_id        Int32 NOT NULL,
    info_type_id    Int32 NOT NULL,
    info            String NOT NULL,
    note            String,
    PRIMARY KEY (id)
);

CREATE TABLE movie_keyword (
    id            Int32 NOT NULL,
    movie_id      Int32 NOT NULL,
    keyword_id    Int32 NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE movie_link (
    id                 Int32 NOT NULL,
    movie_id           Int32 NOT NULL,
    linked_movie_id    Int32 NOT NULL,
    link_type_id       Int32 NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE name (
    id               Int32 NOT NULL,
    name             String NOT NULL,
    imdb_index       String,
    imdb_id          Int32,
    gender           String,
    name_pcode_cf    String,
    name_pcode_nf    String,
    surname_pcode    String,
    md5sum           String,
    PRIMARY KEY (id)
);

CREATE TABLE person_info (
    id              Int32 NOT NULL,
    person_id       Int32 NOT NULL,
    info_type_id    Int32 NOT NULL,
    info            String NOT NULL,
    note            String,
    PRIMARY KEY (id)
);

CREATE TABLE role_type (
    id      Int32 NOT NULL,
    "role"    String NOT NULL,
    PRIMARY KEY (id)
);

CREATE TABLE title (
    id                 Int32 NOT NULL,
    title              String NOT NULL,
    imdb_index         String,
    kind_id            Int32 NOT NULL,
    production_year    Int32,
    imdb_id            Int32,
    phonetic_code      String,
    episode_of_id      Int32,
    season_nr          Int32,
    episode_nr         Int32,
    series_years       String,
    md5sum             String,
    PRIMARY KEY (id)
);
