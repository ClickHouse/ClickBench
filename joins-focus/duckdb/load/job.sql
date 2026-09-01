-- JOB load for DuckDB.

INSERT INTO aka_name SELECT * FROM read_parquet('{{DATA}}/parquet/job/aka_name.parquet');
INSERT INTO aka_title SELECT * FROM read_parquet('{{DATA}}/parquet/job/aka_title.parquet');
INSERT INTO cast_info SELECT * FROM read_parquet('{{DATA}}/parquet/job/cast_info.parquet');
INSERT INTO char_name SELECT * FROM read_parquet('{{DATA}}/parquet/job/char_name.parquet');
INSERT INTO comp_cast_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/comp_cast_type.parquet');
INSERT INTO company_name SELECT * FROM read_parquet('{{DATA}}/parquet/job/company_name.parquet');
INSERT INTO company_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/company_type.parquet');
INSERT INTO complete_cast SELECT * FROM read_parquet('{{DATA}}/parquet/job/complete_cast.parquet');
INSERT INTO info_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/info_type.parquet');
INSERT INTO keyword SELECT * FROM read_parquet('{{DATA}}/parquet/job/keyword.parquet');
INSERT INTO kind_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/kind_type.parquet');
INSERT INTO link_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/link_type.parquet');
INSERT INTO movie_companies SELECT * FROM read_parquet('{{DATA}}/parquet/job/movie_companies.parquet');
INSERT INTO movie_info SELECT * FROM read_parquet('{{DATA}}/parquet/job/movie_info.parquet');
INSERT INTO movie_info_idx SELECT * FROM read_parquet('{{DATA}}/parquet/job/movie_info_idx.parquet');
INSERT INTO movie_keyword SELECT * FROM read_parquet('{{DATA}}/parquet/job/movie_keyword.parquet');
INSERT INTO movie_link SELECT * FROM read_parquet('{{DATA}}/parquet/job/movie_link.parquet');
INSERT INTO name SELECT * FROM read_parquet('{{DATA}}/parquet/job/name.parquet');
INSERT INTO person_info SELECT * FROM read_parquet('{{DATA}}/parquet/job/person_info.parquet');
INSERT INTO role_type SELECT * FROM read_parquet('{{DATA}}/parquet/job/role_type.parquet');
INSERT INTO title SELECT * FROM read_parquet('{{DATA}}/parquet/job/title.parquet');
