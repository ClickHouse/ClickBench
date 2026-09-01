-- Firebolt Core has no schema inference for external tables, so the column list is
-- repeated here. NOT NULL is omitted: the external table only describes the file.

DROP TABLE IF EXISTS nation_ext;
CREATE EXTERNAL TABLE nation_ext
(
    n_nationkey INT,
    n_name TEXT,
    n_regionkey INT,
    n_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'nation.parquet'
TYPE = PARQUET;
INSERT INTO nation SELECT * FROM nation_ext;

DROP TABLE IF EXISTS region_ext;
CREATE EXTERNAL TABLE region_ext
(
    r_regionkey INT,
    r_name TEXT,
    r_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'region.parquet'
TYPE = PARQUET;
INSERT INTO region SELECT * FROM region_ext;

DROP TABLE IF EXISTS part_ext;
CREATE EXTERNAL TABLE part_ext
(
    p_partkey BIGINT,
    p_name TEXT,
    p_mfgr TEXT,
    p_brand TEXT,
    p_type TEXT,
    p_size INT,
    p_container TEXT,
    p_retailprice DECIMAL(15,2),
    p_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'part.parquet'
TYPE = PARQUET;
INSERT INTO part SELECT * FROM part_ext;

DROP TABLE IF EXISTS supplier_ext;
CREATE EXTERNAL TABLE supplier_ext
(
    s_suppkey BIGINT,
    s_name TEXT,
    s_address TEXT,
    s_nationkey INT,
    s_phone TEXT,
    s_acctbal DECIMAL(15,2),
    s_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'supplier.parquet'
TYPE = PARQUET;
INSERT INTO supplier SELECT * FROM supplier_ext;

DROP TABLE IF EXISTS partsupp_ext;
CREATE EXTERNAL TABLE partsupp_ext
(
    ps_partkey BIGINT,
    ps_suppkey BIGINT,
    ps_availqty BIGINT,
    ps_supplycost DECIMAL(15,2),
    ps_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'partsupp.parquet'
TYPE = PARQUET;
INSERT INTO partsupp SELECT * FROM partsupp_ext;

DROP TABLE IF EXISTS customer_ext;
CREATE EXTERNAL TABLE customer_ext
(
    c_custkey BIGINT,
    c_name TEXT,
    c_address TEXT,
    c_nationkey INT,
    c_phone TEXT,
    c_acctbal DECIMAL(15,2),
    c_mktsegment TEXT,
    c_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'customer.parquet'
TYPE = PARQUET;
INSERT INTO customer SELECT * FROM customer_ext;

DROP TABLE IF EXISTS orders_ext;
CREATE EXTERNAL TABLE orders_ext
(
    o_orderkey BIGINT,
    o_custkey BIGINT,
    o_orderstatus TEXT,
    o_totalprice DECIMAL(15,2),
    o_orderdate DATE,
    o_orderpriority TEXT,
    o_clerk TEXT,
    o_shippriority INT,
    o_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'orders.parquet'
TYPE = PARQUET;
INSERT INTO orders SELECT * FROM orders_ext;

DROP TABLE IF EXISTS lineitem_ext;
CREATE EXTERNAL TABLE lineitem_ext
(
    l_orderkey BIGINT,
    l_partkey BIGINT,
    l_suppkey BIGINT,
    l_linenumber BIGINT,
    l_quantity DECIMAL(15,2),
    l_extendedprice DECIMAL(15,2),
    l_discount DECIMAL(15,2),
    l_tax DECIMAL(15,2),
    l_returnflag TEXT,
    l_linestatus TEXT,
    l_shipdate DATE,
    l_commitdate DATE,
    l_receiptdate DATE,
    l_shipinstruct TEXT,
    l_shipmode TEXT,
    l_comment TEXT
)
URL = 'file://{{DATA}}/parquet/tpch/'
OBJECT_PATTERN = 'lineitem.parquet'
TYPE = PARQUET;
INSERT INTO lineitem SELECT * FROM lineitem_ext;

-- No statistics step: Firebolt Core does not implement ANALYZE in any form, so this
-- system runs without collected statistics. That is a real difference from the other
-- six, not an omission here.
