-- JOB load for Umbra. Umbra has no Parquet reader, so it loads the CSV
-- export. NULL is \N there, which is how an empty string stays distinguishable
-- from a NULL.

COPY job.aka_name FROM '{{DATA}}/csv/job/aka_name.csv' (FORMAT csv, NULL '\N');
COPY job.aka_title FROM '{{DATA}}/csv/job/aka_title.csv' (FORMAT csv, NULL '\N');
COPY job.cast_info FROM '{{DATA}}/csv/job/cast_info.csv' (FORMAT csv, NULL '\N');
COPY job.char_name FROM '{{DATA}}/csv/job/char_name.csv' (FORMAT csv, NULL '\N');
COPY job.comp_cast_type FROM '{{DATA}}/csv/job/comp_cast_type.csv' (FORMAT csv, NULL '\N');
COPY job.company_name FROM '{{DATA}}/csv/job/company_name.csv' (FORMAT csv, NULL '\N');
COPY job.company_type FROM '{{DATA}}/csv/job/company_type.csv' (FORMAT csv, NULL '\N');
COPY job.complete_cast FROM '{{DATA}}/csv/job/complete_cast.csv' (FORMAT csv, NULL '\N');
COPY job.info_type FROM '{{DATA}}/csv/job/info_type.csv' (FORMAT csv, NULL '\N');
COPY job.keyword FROM '{{DATA}}/csv/job/keyword.csv' (FORMAT csv, NULL '\N');
COPY job.kind_type FROM '{{DATA}}/csv/job/kind_type.csv' (FORMAT csv, NULL '\N');
COPY job.link_type FROM '{{DATA}}/csv/job/link_type.csv' (FORMAT csv, NULL '\N');
COPY job.movie_companies FROM '{{DATA}}/csv/job/movie_companies.csv' (FORMAT csv, NULL '\N');
COPY job.movie_info FROM '{{DATA}}/csv/job/movie_info.csv' (FORMAT csv, NULL '\N');
COPY job.movie_info_idx FROM '{{DATA}}/csv/job/movie_info_idx.csv' (FORMAT csv, NULL '\N');
COPY job.movie_keyword FROM '{{DATA}}/csv/job/movie_keyword.csv' (FORMAT csv, NULL '\N');
COPY job.movie_link FROM '{{DATA}}/csv/job/movie_link.csv' (FORMAT csv, NULL '\N');
COPY job.name FROM '{{DATA}}/csv/job/name.csv' (FORMAT csv, NULL '\N');
COPY job.person_info FROM '{{DATA}}/csv/job/person_info.csv' (FORMAT csv, NULL '\N');
COPY job.role_type FROM '{{DATA}}/csv/job/role_type.csv' (FORMAT csv, NULL '\N');
COPY job.title FROM '{{DATA}}/csv/job/title.csv' (FORMAT csv, NULL '\N');
