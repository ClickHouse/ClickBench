-- TPCH schema for Doris. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE DATABASE IF NOT EXISTS tpch;
-- Selected once for the whole script: the runner feeds this file to a single
-- mysql session, so every table below can be named unqualified.
USE tpch;

DROP TABLE IF EXISTS lineitem;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS partsupp;
DROP TABLE IF EXISTS supplier;
DROP TABLE IF EXISTS part;
DROP TABLE IF EXISTS region;
DROP TABLE IF EXISTS nation;

CREATE TABLE nation (
    n_nationkey INT NOT NULL,
    n_name      CHAR(25) NOT NULL,
    n_regionkey INT NOT NULL,
    n_comment   VARCHAR(152))
DUPLICATE KEY(n_nationkey)
PROPERTIES('replication_num'='1');

CREATE TABLE region (
    r_regionkey INT NOT NULL,
    r_name      CHAR(25) NOT NULL,
    r_comment   VARCHAR(152))
DUPLICATE KEY(r_regionkey)
PROPERTIES('replication_num'='1');

CREATE TABLE part (
    p_partkey     INT NOT NULL,
    p_name        VARCHAR(55) NOT NULL,
    p_mfgr        CHAR(25) NOT NULL,
    p_brand       CHAR(10) NOT NULL,
    p_type        VARCHAR(25) NOT NULL,
    p_size        INT NOT NULL,
    p_container   CHAR(10) NOT NULL,
    p_retailprice DECIMAL(15,2) NOT NULL,
    p_comment     VARCHAR(23) NOT NULL)
DUPLICATE KEY(p_partkey)
PROPERTIES('replication_num'='1');

CREATE TABLE supplier (
    s_suppkey   INT NOT NULL,
    s_name      CHAR(25) NOT NULL,
    s_address   VARCHAR(40) NOT NULL,
    s_nationkey INT NOT NULL,
    s_phone     CHAR(15) NOT NULL,
    s_acctbal   DECIMAL(15,2) NOT NULL,
    s_comment   VARCHAR(101) NOT NULL)
DUPLICATE KEY(s_suppkey)
PROPERTIES('replication_num'='1');

CREATE TABLE partsupp (
    ps_partkey    INT NOT NULL,
    ps_suppkey    INT NOT NULL,
    ps_availqty   INT NOT NULL,
    ps_supplycost DECIMAL(15,2) NOT NULL,
    ps_comment    VARCHAR(199) NOT NULL)
DUPLICATE KEY(ps_partkey, ps_suppkey)
PROPERTIES('replication_num'='1');

CREATE TABLE customer (
    c_custkey    INT NOT NULL,
    c_name       VARCHAR(25) NOT NULL,
    c_address    VARCHAR(40) NOT NULL,
    c_nationkey  INT NOT NULL,
    c_phone      CHAR(15) NOT NULL,
    c_acctbal    DECIMAL(15,2) NOT NULL,
    c_mktsegment CHAR(10) NOT NULL,
    c_comment    VARCHAR(117) NOT NULL)
DUPLICATE KEY(c_custkey)
PROPERTIES('replication_num'='1');

CREATE TABLE orders (
    o_orderkey      INT NOT NULL,
    o_custkey       INT NOT NULL,
    o_orderstatus   CHAR(1) NOT NULL,
    o_totalprice    DECIMAL(15,2) NOT NULL,
    o_orderdate     DATE NOT NULL,
    o_orderpriority CHAR(15) NOT NULL,
    o_clerk         CHAR(15) NOT NULL,
    o_shippriority  INT NOT NULL,
    o_comment       VARCHAR(79) NOT NULL)
DUPLICATE KEY(o_orderkey)
PROPERTIES('replication_num'='1');

CREATE TABLE lineitem (
    l_orderkey      INT NOT NULL,
    l_linenumber    INT NOT NULL,
    l_partkey       INT NOT NULL,
    l_suppkey       INT NOT NULL,
    l_quantity      DECIMAL(15,2) NOT NULL,
    l_extendedprice DECIMAL(15,2) NOT NULL,
    l_discount      DECIMAL(15,2) NOT NULL,
    l_tax           DECIMAL(15,2) NOT NULL,
    l_returnflag    CHAR(1) NOT NULL,
    l_linestatus    CHAR(1) NOT NULL,
    l_shipdate      DATE NOT NULL,
    l_commitdate    DATE NOT NULL,
    l_receiptdate   DATE NOT NULL,
    l_shipinstruct  CHAR(25) NOT NULL,
    l_shipmode      CHAR(10) NOT NULL,
    l_comment       VARCHAR(44) NOT NULL)
DUPLICATE KEY(l_orderkey, l_linenumber)
PROPERTIES('replication_num'='1');

