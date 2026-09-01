-- Firebolt Core has no schema inference for external tables, so the column list is
-- repeated here. NOT NULL is omitted: the external table only describes the file.

DROP TABLE IF EXISTS aka_name_ext;
CREATE EXTERNAL TABLE aka_name_ext
(
    id INT,
    person_id INT,
    name TEXT,
    imdb_index TEXT,
    name_pcode_cf TEXT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'aka_name.parquet'
TYPE = PARQUET;
INSERT INTO aka_name SELECT * FROM aka_name_ext;

DROP TABLE IF EXISTS aka_title_ext;
CREATE EXTERNAL TABLE aka_title_ext
(
    id INT,
    movie_id INT,
    title TEXT,
    imdb_index TEXT,
    kind_id INT,
    production_year INT,
    phonetic_code TEXT,
    episode_of_id INT,
    season_nr INT,
    episode_nr INT,
    note TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'aka_title.parquet'
TYPE = PARQUET;
INSERT INTO aka_title SELECT * FROM aka_title_ext;

DROP TABLE IF EXISTS cast_info_ext;
CREATE EXTERNAL TABLE cast_info_ext
(
    id INT,
    person_id INT,
    movie_id INT,
    person_role_id INT,
    note TEXT,
    nr_order INT,
    role_id INT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'cast_info.parquet'
TYPE = PARQUET;
INSERT INTO cast_info SELECT * FROM cast_info_ext;

DROP TABLE IF EXISTS char_name_ext;
CREATE EXTERNAL TABLE char_name_ext
(
    id INT,
    name TEXT,
    imdb_index TEXT,
    imdb_id INT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'char_name.parquet'
TYPE = PARQUET;
INSERT INTO char_name SELECT * FROM char_name_ext;

DROP TABLE IF EXISTS comp_cast_type_ext;
CREATE EXTERNAL TABLE comp_cast_type_ext
(
    id INT,
    kind TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'comp_cast_type.parquet'
TYPE = PARQUET;
INSERT INTO comp_cast_type SELECT * FROM comp_cast_type_ext;

DROP TABLE IF EXISTS company_name_ext;
CREATE EXTERNAL TABLE company_name_ext
(
    id INT,
    name TEXT,
    country_code TEXT,
    imdb_id INT,
    name_pcode_nf TEXT,
    name_pcode_sf TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'company_name.parquet'
TYPE = PARQUET;
INSERT INTO company_name SELECT * FROM company_name_ext;

DROP TABLE IF EXISTS company_type_ext;
CREATE EXTERNAL TABLE company_type_ext
(
    id INT,
    kind TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'company_type.parquet'
TYPE = PARQUET;
INSERT INTO company_type SELECT * FROM company_type_ext;

DROP TABLE IF EXISTS complete_cast_ext;
CREATE EXTERNAL TABLE complete_cast_ext
(
    id INT,
    movie_id INT,
    subject_id INT,
    status_id INT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'complete_cast.parquet'
TYPE = PARQUET;
INSERT INTO complete_cast SELECT * FROM complete_cast_ext;

DROP TABLE IF EXISTS info_type_ext;
CREATE EXTERNAL TABLE info_type_ext
(
    id INT,
    info TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'info_type.parquet'
TYPE = PARQUET;
INSERT INTO info_type SELECT * FROM info_type_ext;

DROP TABLE IF EXISTS keyword_ext;
CREATE EXTERNAL TABLE keyword_ext
(
    id INT,
    keyword TEXT,
    phonetic_code TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'keyword.parquet'
TYPE = PARQUET;
INSERT INTO keyword SELECT * FROM keyword_ext;

DROP TABLE IF EXISTS kind_type_ext;
CREATE EXTERNAL TABLE kind_type_ext
(
    id INT,
    kind TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'kind_type.parquet'
TYPE = PARQUET;
INSERT INTO kind_type SELECT * FROM kind_type_ext;

DROP TABLE IF EXISTS link_type_ext;
CREATE EXTERNAL TABLE link_type_ext
(
    id INT,
    link TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'link_type.parquet'
TYPE = PARQUET;
INSERT INTO link_type SELECT * FROM link_type_ext;

DROP TABLE IF EXISTS movie_companies_ext;
CREATE EXTERNAL TABLE movie_companies_ext
(
    id INT,
    movie_id INT,
    company_id INT,
    company_type_id INT,
    note TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'movie_companies.parquet'
TYPE = PARQUET;
INSERT INTO movie_companies SELECT * FROM movie_companies_ext;

DROP TABLE IF EXISTS movie_info_ext;
CREATE EXTERNAL TABLE movie_info_ext
(
    id INT,
    movie_id INT,
    info_type_id INT,
    info TEXT,
    note TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'movie_info.parquet'
TYPE = PARQUET;
INSERT INTO movie_info SELECT * FROM movie_info_ext;

DROP TABLE IF EXISTS movie_info_idx_ext;
CREATE EXTERNAL TABLE movie_info_idx_ext
(
    id INT,
    movie_id INT,
    info_type_id INT,
    info TEXT,
    note TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'movie_info_idx.parquet'
TYPE = PARQUET;
INSERT INTO movie_info_idx SELECT * FROM movie_info_idx_ext;

DROP TABLE IF EXISTS movie_keyword_ext;
CREATE EXTERNAL TABLE movie_keyword_ext
(
    id INT,
    movie_id INT,
    keyword_id INT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'movie_keyword.parquet'
TYPE = PARQUET;
INSERT INTO movie_keyword SELECT * FROM movie_keyword_ext;

DROP TABLE IF EXISTS movie_link_ext;
CREATE EXTERNAL TABLE movie_link_ext
(
    id INT,
    movie_id INT,
    linked_movie_id INT,
    link_type_id INT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'movie_link.parquet'
TYPE = PARQUET;
INSERT INTO movie_link SELECT * FROM movie_link_ext;

DROP TABLE IF EXISTS name_ext;
CREATE EXTERNAL TABLE name_ext
(
    id INT,
    name TEXT,
    imdb_index TEXT,
    imdb_id INT,
    gender TEXT,
    name_pcode_cf TEXT,
    name_pcode_nf TEXT,
    surname_pcode TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'name.parquet'
TYPE = PARQUET;
INSERT INTO name SELECT * FROM name_ext;

DROP TABLE IF EXISTS person_info_ext;
CREATE EXTERNAL TABLE person_info_ext
(
    id INT,
    person_id INT,
    info_type_id INT,
    info TEXT,
    note TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'person_info.parquet'
TYPE = PARQUET;
INSERT INTO person_info SELECT * FROM person_info_ext;

DROP TABLE IF EXISTS role_type_ext;
CREATE EXTERNAL TABLE role_type_ext
(
    id INT,
    "role" TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'role_type.parquet'
TYPE = PARQUET;
INSERT INTO role_type SELECT * FROM role_type_ext;

DROP TABLE IF EXISTS title_ext;
CREATE EXTERNAL TABLE title_ext
(
    id INT,
    title TEXT,
    imdb_index TEXT,
    kind_id INT,
    production_year INT,
    imdb_id INT,
    phonetic_code TEXT,
    episode_of_id INT,
    season_nr INT,
    episode_nr INT,
    series_years TEXT,
    md5sum TEXT
)
URL = 'file://{{DATA}}/parquet/job/'
OBJECT_PATTERN = 'title.parquet'
TYPE = PARQUET;
INSERT INTO title SELECT * FROM title_ext;

-- No statistics step: Firebolt Core does not implement ANALYZE in any form, so this
-- system runs without collected statistics. That is a real difference from the other
-- six, not an omission here.
