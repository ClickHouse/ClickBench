-- TPCH load for StarRocks.

INSERT INTO tpch.nation SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/nation.parquet','format'='parquet');
INSERT INTO tpch.region SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/region.parquet','format'='parquet');
INSERT INTO tpch.part SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/part.parquet','format'='parquet');
INSERT INTO tpch.supplier SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/supplier.parquet','format'='parquet');
INSERT INTO tpch.partsupp SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/partsupp.parquet','format'='parquet');
INSERT INTO tpch.customer SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/customer.parquet','format'='parquet');
INSERT INTO tpch.orders SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/orders.parquet','format'='parquet');
INSERT INTO tpch.lineitem SELECT * FROM FILES('path'='{{DATA}}/parquet/tpch/lineitem.parquet','format'='parquet');
