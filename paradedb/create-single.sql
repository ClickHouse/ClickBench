CREATE FOREIGN DATA WRAPPER parquet_wrapper
    HANDLER parquet_fdw_handler
    VALIDATOR parquet_fdw_validator;

CREATE SERVER parquet_server
    FOREIGN DATA WRAPPER parquet_wrapper;

CREATE FOREIGN TABLE IF NOT EXISTS hits ()
SERVER parquet_server
OPTIONS (files '/tmp/hits.parquet');
