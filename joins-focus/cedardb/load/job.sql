-- JOB load for CedarDB.

INSERT INTO job.aka_name SELECT * FROM '{{DATA}}/parquet/job/aka_name.parquet';
INSERT INTO job.aka_title SELECT * FROM '{{DATA}}/parquet/job/aka_title.parquet';
INSERT INTO job.cast_info SELECT * FROM '{{DATA}}/parquet/job/cast_info.parquet';
INSERT INTO job.char_name SELECT * FROM '{{DATA}}/parquet/job/char_name.parquet';
INSERT INTO job.comp_cast_type SELECT * FROM '{{DATA}}/parquet/job/comp_cast_type.parquet';
INSERT INTO job.company_name SELECT * FROM '{{DATA}}/parquet/job/company_name.parquet';
INSERT INTO job.company_type SELECT * FROM '{{DATA}}/parquet/job/company_type.parquet';
INSERT INTO job.complete_cast SELECT * FROM '{{DATA}}/parquet/job/complete_cast.parquet';
INSERT INTO job.info_type SELECT * FROM '{{DATA}}/parquet/job/info_type.parquet';
INSERT INTO job.keyword SELECT * FROM '{{DATA}}/parquet/job/keyword.parquet';
INSERT INTO job.kind_type SELECT * FROM '{{DATA}}/parquet/job/kind_type.parquet';
INSERT INTO job.link_type SELECT * FROM '{{DATA}}/parquet/job/link_type.parquet';
INSERT INTO job.movie_companies SELECT * FROM '{{DATA}}/parquet/job/movie_companies.parquet';
INSERT INTO job.movie_info SELECT * FROM '{{DATA}}/parquet/job/movie_info.parquet';
INSERT INTO job.movie_info_idx SELECT * FROM '{{DATA}}/parquet/job/movie_info_idx.parquet';
INSERT INTO job.movie_keyword SELECT * FROM '{{DATA}}/parquet/job/movie_keyword.parquet';
INSERT INTO job.movie_link SELECT * FROM '{{DATA}}/parquet/job/movie_link.parquet';
INSERT INTO job.name SELECT * FROM '{{DATA}}/parquet/job/name.parquet';
INSERT INTO job.person_info SELECT * FROM '{{DATA}}/parquet/job/person_info.parquet';
INSERT INTO job.role_type SELECT * FROM '{{DATA}}/parquet/job/role_type.parquet';
INSERT INTO job.title SELECT * FROM '{{DATA}}/parquet/job/title.parquet';
