-- TPCH load for ClickHouse. Read SERVER-SIDE with file(), which parallelises across
-- threads; the data directory is mounted read-only at /data and user_files_path points
-- there (config.d/user_files.xml), because file() refuses paths outside it.
--
-- This replaces streaming the Parquet into clickhouse-client's stdin. That path was a
-- single serialized byte stream through a docker exec socket, decoded one block at a
-- time: 24 GB of TPC-H SF100 lineitem took 1235s, about 20 MB/s, on a 32-core host.

INSERT INTO tpch.nation SELECT * FROM file('{{DATA}}/parquet/tpch/nation.parquet', Parquet);
INSERT INTO tpch.region SELECT * FROM file('{{DATA}}/parquet/tpch/region.parquet', Parquet);
INSERT INTO tpch.part SELECT * FROM file('{{DATA}}/parquet/tpch/part.parquet', Parquet);
INSERT INTO tpch.supplier SELECT * FROM file('{{DATA}}/parquet/tpch/supplier.parquet', Parquet);
INSERT INTO tpch.partsupp SELECT * FROM file('{{DATA}}/parquet/tpch/partsupp.parquet', Parquet);
INSERT INTO tpch.customer SELECT * FROM file('{{DATA}}/parquet/tpch/customer.parquet', Parquet);
INSERT INTO tpch.orders SELECT * FROM file('{{DATA}}/parquet/tpch/orders.parquet', Parquet);
INSERT INTO tpch.lineitem SELECT * FROM file('{{DATA}}/parquet/tpch/lineitem.parquet', Parquet);
