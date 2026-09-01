-- JOB load for ClickHouse. Read SERVER-SIDE with file(), which parallelises across
-- threads; the data directory is mounted read-only at /data and user_files_path points
-- there (config.d/user_files.xml), because file() refuses paths outside it.
--
-- This replaces streaming the Parquet into clickhouse-client's stdin. That path was a
-- single serialized byte stream through a docker exec socket, decoded one block at a
-- time: 24 GB of TPC-H SF100 lineitem took 1235s, about 20 MB/s, on a 32-core host.

INSERT INTO job.aka_name SELECT * FROM file('{{DATA}}/parquet/job/aka_name.parquet', Parquet);
INSERT INTO job.aka_title SELECT * FROM file('{{DATA}}/parquet/job/aka_title.parquet', Parquet);
INSERT INTO job.cast_info SELECT * FROM file('{{DATA}}/parquet/job/cast_info.parquet', Parquet);
INSERT INTO job.char_name SELECT * FROM file('{{DATA}}/parquet/job/char_name.parquet', Parquet);
INSERT INTO job.comp_cast_type SELECT * FROM file('{{DATA}}/parquet/job/comp_cast_type.parquet', Parquet);
INSERT INTO job.company_name SELECT * FROM file('{{DATA}}/parquet/job/company_name.parquet', Parquet);
INSERT INTO job.company_type SELECT * FROM file('{{DATA}}/parquet/job/company_type.parquet', Parquet);
INSERT INTO job.complete_cast SELECT * FROM file('{{DATA}}/parquet/job/complete_cast.parquet', Parquet);
INSERT INTO job.info_type SELECT * FROM file('{{DATA}}/parquet/job/info_type.parquet', Parquet);
INSERT INTO job.keyword SELECT * FROM file('{{DATA}}/parquet/job/keyword.parquet', Parquet);
INSERT INTO job.kind_type SELECT * FROM file('{{DATA}}/parquet/job/kind_type.parquet', Parquet);
INSERT INTO job.link_type SELECT * FROM file('{{DATA}}/parquet/job/link_type.parquet', Parquet);
INSERT INTO job.movie_companies SELECT * FROM file('{{DATA}}/parquet/job/movie_companies.parquet', Parquet);
INSERT INTO job.movie_info SELECT * FROM file('{{DATA}}/parquet/job/movie_info.parquet', Parquet);
INSERT INTO job.movie_info_idx SELECT * FROM file('{{DATA}}/parquet/job/movie_info_idx.parquet', Parquet);
INSERT INTO job.movie_keyword SELECT * FROM file('{{DATA}}/parquet/job/movie_keyword.parquet', Parquet);
INSERT INTO job.movie_link SELECT * FROM file('{{DATA}}/parquet/job/movie_link.parquet', Parquet);
INSERT INTO job.name SELECT * FROM file('{{DATA}}/parquet/job/name.parquet', Parquet);
INSERT INTO job.person_info SELECT * FROM file('{{DATA}}/parquet/job/person_info.parquet', Parquet);
INSERT INTO job.role_type SELECT * FROM file('{{DATA}}/parquet/job/role_type.parquet', Parquet);
INSERT INTO job.title SELECT * FROM file('{{DATA}}/parquet/job/title.parquet', Parquet);
