-- TPCH load for DuckDB.

INSERT INTO nation SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/nation.parquet');
INSERT INTO region SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/region.parquet');
INSERT INTO part SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/part.parquet');
INSERT INTO supplier SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/supplier.parquet');
INSERT INTO partsupp SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/partsupp.parquet');
INSERT INTO customer SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/customer.parquet');
INSERT INTO orders SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/orders.parquet');
INSERT INTO lineitem SELECT * FROM read_parquet('{{DATA}}/parquet/tpch/lineitem.parquet');
