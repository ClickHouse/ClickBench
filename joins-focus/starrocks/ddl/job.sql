-- NOTE: `role` is quoted throughout. It is a reserved word in the MySQL-family dialects
-- (Doris rejects it outright: "no viable alternative at input ',\n    role'"), and the JOB
-- schema names a column that. Nothing else in any of the three schemas needs quoting.
-- JOB schema for starrocks, generated at scale-independent types and then
-- maintained BY HAND. Column order matches the generator output and is positional on
-- load -- reordering a column here silently corrupts that table.

CREATE DATABASE IF NOT EXISTS job;

DROP TABLE IF EXISTS job.aka_name;
CREATE TABLE job.aka_name
(
    id INT NOT NULL,
    person_id INT NOT NULL,
    name VARCHAR(65533) NOT NULL,
    imdb_index VARCHAR(12),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum VARCHAR(32)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.aka_title;
CREATE TABLE job.aka_title
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    title VARCHAR(65533) NOT NULL,
    imdb_index VARCHAR(12),
    kind_id INT NOT NULL,
    production_year INT,
    phonetic_code VARCHAR(5),
    episode_of_id INT,
    season_nr INT,
    episode_nr INT,
    note VARCHAR(65533),
    md5sum VARCHAR(32)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.cast_info;
CREATE TABLE job.cast_info
(
    id INT NOT NULL,
    person_id INT NOT NULL,
    movie_id INT NOT NULL,
    person_role_id INT,
    note VARCHAR(65533),
    nr_order INT,
    role_id INT NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.char_name;
CREATE TABLE job.char_name
(
    id INT NOT NULL,
    name VARCHAR(65533) NOT NULL,
    imdb_index VARCHAR(12),
    imdb_id INT,
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum VARCHAR(32)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.comp_cast_type;
CREATE TABLE job.comp_cast_type
(
    id INT NOT NULL,
    kind VARCHAR(32) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.company_name;
CREATE TABLE job.company_name
(
    id INT NOT NULL,
    name VARCHAR(65533) NOT NULL,
    country_code VARCHAR(255),
    imdb_id INT,
    name_pcode_nf VARCHAR(5),
    name_pcode_sf VARCHAR(5),
    md5sum VARCHAR(32)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.company_type;
CREATE TABLE job.company_type
(
    id INT NOT NULL,
    kind VARCHAR(32) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.complete_cast;
CREATE TABLE job.complete_cast
(
    id INT NOT NULL,
    movie_id INT,
    subject_id INT NOT NULL,
    status_id INT NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.info_type;
CREATE TABLE job.info_type
(
    id INT NOT NULL,
    info VARCHAR(32) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.keyword;
CREATE TABLE job.keyword
(
    id INT NOT NULL,
    keyword VARCHAR(65533) NOT NULL,
    phonetic_code VARCHAR(5)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.kind_type;
CREATE TABLE job.kind_type
(
    id INT NOT NULL,
    kind VARCHAR(15) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.link_type;
CREATE TABLE job.link_type
(
    id INT NOT NULL,
    link VARCHAR(32) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.movie_companies;
CREATE TABLE job.movie_companies
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    company_id INT NOT NULL,
    company_type_id INT NOT NULL,
    note VARCHAR(65533)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.movie_info;
CREATE TABLE job.movie_info
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    info_type_id INT NOT NULL,
    info VARCHAR(65533) NOT NULL,
    note VARCHAR(65533)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.movie_info_idx;
CREATE TABLE job.movie_info_idx
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    info_type_id INT NOT NULL,
    info VARCHAR(65533) NOT NULL,
    note VARCHAR(65533)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.movie_keyword;
CREATE TABLE job.movie_keyword
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    keyword_id INT NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.movie_link;
CREATE TABLE job.movie_link
(
    id INT NOT NULL,
    movie_id INT NOT NULL,
    linked_movie_id INT NOT NULL,
    link_type_id INT NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.name;
CREATE TABLE job.name
(
    id INT NOT NULL,
    name VARCHAR(65533) NOT NULL,
    imdb_index VARCHAR(12),
    imdb_id INT,
    gender VARCHAR(1),
    name_pcode_cf VARCHAR(5),
    name_pcode_nf VARCHAR(5),
    surname_pcode VARCHAR(5),
    md5sum VARCHAR(32)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.person_info;
CREATE TABLE job.person_info
(
    id INT NOT NULL,
    person_id INT NOT NULL,
    info_type_id INT NOT NULL,
    info VARCHAR(65533) NOT NULL,
    note VARCHAR(65533)
)
ORDER BY (id);

DROP TABLE IF EXISTS job.role_type;
CREATE TABLE job.role_type
(
    id INT NOT NULL,
    `role` VARCHAR(32) NOT NULL
)
ORDER BY (id);

DROP TABLE IF EXISTS job.title;
CREATE TABLE job.title
(
    id INT NOT NULL,
    title VARCHAR(65533) NOT NULL,
    imdb_index VARCHAR(12),
    kind_id INT NOT NULL,
    production_year INT,
    imdb_id INT,
    phonetic_code VARCHAR(5),
    episode_of_id INT,
    season_nr INT,
    episode_nr INT,
    series_years VARCHAR(49),
    md5sum VARCHAR(32)
)
ORDER BY (id);
