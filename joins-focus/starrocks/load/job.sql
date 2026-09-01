-- JOB load for StarRocks.

INSERT INTO job.aka_name SELECT * FROM FILES('path'='{{DATA}}/parquet/job/aka_name.parquet','format'='parquet');
INSERT INTO job.aka_title SELECT * FROM FILES('path'='{{DATA}}/parquet/job/aka_title.parquet','format'='parquet');
INSERT INTO job.cast_info SELECT * FROM FILES('path'='{{DATA}}/parquet/job/cast_info.parquet','format'='parquet');
INSERT INTO job.char_name SELECT * FROM FILES('path'='{{DATA}}/parquet/job/char_name.parquet','format'='parquet');
INSERT INTO job.comp_cast_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/comp_cast_type.parquet','format'='parquet');
INSERT INTO job.company_name SELECT * FROM FILES('path'='{{DATA}}/parquet/job/company_name.parquet','format'='parquet');
INSERT INTO job.company_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/company_type.parquet','format'='parquet');
INSERT INTO job.complete_cast SELECT * FROM FILES('path'='{{DATA}}/parquet/job/complete_cast.parquet','format'='parquet');
INSERT INTO job.info_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/info_type.parquet','format'='parquet');
INSERT INTO job.keyword SELECT * FROM FILES('path'='{{DATA}}/parquet/job/keyword.parquet','format'='parquet');
INSERT INTO job.kind_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/kind_type.parquet','format'='parquet');
INSERT INTO job.link_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/link_type.parquet','format'='parquet');
INSERT INTO job.movie_companies SELECT * FROM FILES('path'='{{DATA}}/parquet/job/movie_companies.parquet','format'='parquet');
INSERT INTO job.movie_info SELECT * FROM FILES('path'='{{DATA}}/parquet/job/movie_info.parquet','format'='parquet');
INSERT INTO job.movie_info_idx SELECT * FROM FILES('path'='{{DATA}}/parquet/job/movie_info_idx.parquet','format'='parquet');
INSERT INTO job.movie_keyword SELECT * FROM FILES('path'='{{DATA}}/parquet/job/movie_keyword.parquet','format'='parquet');
INSERT INTO job.movie_link SELECT * FROM FILES('path'='{{DATA}}/parquet/job/movie_link.parquet','format'='parquet');
INSERT INTO job.name SELECT * FROM FILES('path'='{{DATA}}/parquet/job/name.parquet','format'='parquet');
INSERT INTO job.person_info SELECT * FROM FILES('path'='{{DATA}}/parquet/job/person_info.parquet','format'='parquet');
INSERT INTO job.role_type SELECT * FROM FILES('path'='{{DATA}}/parquet/job/role_type.parquet','format'='parquet');
INSERT INTO job.title SELECT * FROM FILES('path'='{{DATA}}/parquet/job/title.parquet','format'='parquet');
