-- Table names are UNQUALIFIED: run.sh sends `USE <benchmark>;` before each
-- statement, exactly as the versions benchmark did. Qualifying them instead left no
-- current database, and Doris then failed to resolve local() as a table-valued
-- function -- "Table function must be used with lateral join".
-- TPCH load for Doris.
-- The column list is in GENERATOR order; ddl/ declares key columns first because
-- Doris requires DUPLICATE KEY columns to be a table prefix. Naming them here keeps
-- the positional SELECT landing in the right columns.

INSERT INTO nation (n_nationkey, n_name, n_regionkey, n_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/nation.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO region (r_regionkey, r_name, r_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/region.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO part (p_partkey, p_name, p_mfgr, p_brand, p_type, p_size, p_container, p_retailprice, p_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/part.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO supplier (s_suppkey, s_name, s_address, s_nationkey, s_phone, s_acctbal, s_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/supplier.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO partsupp (ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/partsupp.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO customer (c_custkey, c_name, c_address, c_nationkey, c_phone, c_acctbal, c_mktsegment, c_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/customer.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO orders (o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/orders.parquet','backend_id'='{{BEID}}','format'='parquet');
INSERT INTO lineitem (l_orderkey, l_partkey, l_suppkey, l_linenumber, l_quantity, l_extendedprice, l_discount, l_tax, l_returnflag, l_linestatus, l_shipdate, l_commitdate, l_receiptdate, l_shipinstruct, l_shipmode, l_comment) SELECT * FROM local('file_path'='{{DATA}}/parquet/tpch/lineitem.parquet','backend_id'='{{BEID}}','format'='parquet');
