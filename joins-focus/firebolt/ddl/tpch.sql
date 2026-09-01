-- TPCH schema for Firebolt. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE DATABASE IF NOT EXISTS tpch;

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
    n_name      TEXT NOT NULL,
    n_regionkey INT NOT NULL,
    n_comment   TEXT)
PRIMARY INDEX n_nationkey;

CREATE TABLE region (
    r_regionkey INT NOT NULL,
    r_name      TEXT NOT NULL,
    r_comment   TEXT)
PRIMARY INDEX r_regionkey;

CREATE TABLE part (
    p_partkey     INT NOT NULL,
    p_name        TEXT NOT NULL,
    p_mfgr        TEXT NOT NULL,
    p_brand       TEXT NOT NULL,
    p_type        TEXT NOT NULL,
    p_size        INT NOT NULL,
    p_container   TEXT NOT NULL,
    p_retailprice DECIMAL(15,2) NOT NULL,
    p_comment     TEXT NOT NULL)
PRIMARY INDEX p_partkey;

CREATE TABLE supplier (
    s_suppkey   INT NOT NULL,
    s_name      TEXT NOT NULL,
    s_address   TEXT NOT NULL,
    s_nationkey INT NOT NULL,
    s_phone     TEXT NOT NULL,
    s_acctbal   DECIMAL(15,2) NOT NULL,
    s_comment   TEXT NOT NULL)
PRIMARY INDEX s_suppkey;

CREATE TABLE partsupp (
    ps_partkey    INT NOT NULL,
    ps_suppkey    INT NOT NULL,
    ps_availqty   INT NOT NULL,
    ps_supplycost DECIMAL(15,2) NOT NULL,
    ps_comment    TEXT NOT NULL)
PRIMARY INDEX ps_partkey, ps_suppkey;

CREATE TABLE customer (
    c_custkey    INT NOT NULL,
    c_name       TEXT NOT NULL,
    c_address    TEXT NOT NULL,
    c_nationkey  INT NOT NULL,
    c_phone      TEXT NOT NULL,
    c_acctbal    DECIMAL(15,2) NOT NULL,
    c_mktsegment TEXT NOT NULL,
    c_comment    TEXT NOT NULL)
PRIMARY INDEX c_custkey;

CREATE TABLE orders (
    o_orderkey      INT NOT NULL,
    o_custkey       INT NOT NULL,
    o_orderstatus   TEXT NOT NULL,
    o_totalprice    DECIMAL(15,2) NOT NULL,
    o_orderdate     DATE NOT NULL,
    o_orderpriority TEXT NOT NULL,
    o_clerk         TEXT NOT NULL,
    o_shippriority  INT NOT NULL,
    o_comment       TEXT NOT NULL)
PRIMARY INDEX o_orderkey;

CREATE TABLE lineitem (
    l_orderkey      INT NOT NULL,
    l_partkey       INT NOT NULL,
    l_suppkey       INT NOT NULL,
    l_linenumber    INT NOT NULL,
    l_quantity      DECIMAL(15,2) NOT NULL,
    l_extendedprice DECIMAL(15,2) NOT NULL,
    l_discount      DECIMAL(15,2) NOT NULL,
    l_tax           DECIMAL(15,2) NOT NULL,
    l_returnflag    TEXT NOT NULL,
    l_linestatus    TEXT NOT NULL,
    l_shipdate      DATE NOT NULL,
    l_commitdate    DATE NOT NULL,
    l_receiptdate   DATE NOT NULL,
    l_shipinstruct  TEXT NOT NULL,
    l_shipmode      TEXT NOT NULL,
    l_comment       TEXT NOT NULL)
PRIMARY INDEX l_orderkey, l_linenumber;

