-- Table names are UNQUALIFIED: run.sh sends `USE <benchmark>;` before each
-- statement, exactly as the versions benchmark did. Qualifying them instead left no
-- current database, and Doris then failed to resolve local() as a table-valued
-- function -- "Table function must be used with lateral join".
-- JOB load for Doris.
-- The column list is in GENERATOR order; ddl/ declares key columns first because
-- Doris requires DUPLICATE KEY columns to be a table prefix. Naming them here keeps
-- the positional SELECT landing in the right columns.

INSERT INTO aka_name (id, person_id, name, imdb_index, name_pcode_cf, name_pcode_nf, surname_pcode, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/aka_name.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO aka_title (id, movie_id, title, imdb_index, kind_id, production_year, phonetic_code, episode_of_id, season_nr, episode_nr, note, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/aka_title.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO cast_info (id, person_id, movie_id, person_role_id, note, nr_order, role_id) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/cast_info.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO char_name (id, name, imdb_index, imdb_id, name_pcode_nf, surname_pcode, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/char_name.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO comp_cast_type (id, kind) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/comp_cast_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO company_name (id, name, country_code, imdb_id, name_pcode_nf, name_pcode_sf, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/company_name.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO company_type (id, kind) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/company_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO complete_cast (id, movie_id, subject_id, status_id) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/complete_cast.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO info_type (id, info) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/info_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO keyword (id, keyword, phonetic_code) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/keyword.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO kind_type (id, kind) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/kind_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO link_type (id, link) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/link_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO movie_companies (id, movie_id, company_id, company_type_id, note) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/movie_companies.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO movie_info (id, movie_id, info_type_id, info, note) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/movie_info.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO movie_info_idx (id, movie_id, info_type_id, info, note) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/movie_info_idx.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO movie_keyword (id, movie_id, keyword_id) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/movie_keyword.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO movie_link (id, movie_id, linked_movie_id, link_type_id) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/movie_link.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO name (id, name, imdb_index, imdb_id, gender, name_pcode_cf, name_pcode_nf, surname_pcode, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/name.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO person_info (id, person_id, info_type_id, info, note) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/person_info.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO role_type (id, `role`) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/role_type.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO title (id, title, imdb_index, kind_id, production_year, imdb_id, phonetic_code, episode_of_id, season_nr, episode_nr, series_years, md5sum) SELECT * FROM local('file_path'='{{DATA}}/parquet/job/title.parquet','backend_id'='{{BEID}}','format'='parquet');
