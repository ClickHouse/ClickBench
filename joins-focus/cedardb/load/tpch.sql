-- TPCH load for CedarDB.

INSERT INTO tpch.nation SELECT * FROM '{{DATA}}/parquet/tpch/nation.parquet';
INSERT INTO tpch.region SELECT * FROM '{{DATA}}/parquet/tpch/region.parquet';
INSERT INTO tpch.part SELECT * FROM '{{DATA}}/parquet/tpch/part.parquet';
INSERT INTO tpch.supplier SELECT * FROM '{{DATA}}/parquet/tpch/supplier.parquet';
INSERT INTO tpch.partsupp SELECT * FROM '{{DATA}}/parquet/tpch/partsupp.parquet';
INSERT INTO tpch.customer SELECT * FROM '{{DATA}}/parquet/tpch/customer.parquet';
INSERT INTO tpch.orders SELECT * FROM '{{DATA}}/parquet/tpch/orders.parquet';
INSERT INTO tpch.lineitem SELECT * FROM '{{DATA}}/parquet/tpch/lineitem.parquet';
