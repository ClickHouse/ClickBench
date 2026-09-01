-- TPCDS load for ClickHouse. Read SERVER-SIDE with file(), which parallelises across
-- threads; the data directory is mounted read-only at /data and user_files_path points
-- there (config.d/user_files.xml), because file() refuses paths outside it.
--
-- This replaces streaming the Parquet into clickhouse-client's stdin. That path was a
-- single serialized byte stream through a docker exec socket, decoded one block at a
-- time: 24 GB of TPC-H SF100 lineitem took 1235s, about 20 MB/s, on a 32-core host.

INSERT INTO tpcds.call_center SELECT * FROM file('{{DATA}}/parquet/tpcds/call_center.parquet', Parquet);
INSERT INTO tpcds.catalog_page SELECT * FROM file('{{DATA}}/parquet/tpcds/catalog_page.parquet', Parquet);
INSERT INTO tpcds.catalog_returns SELECT * FROM file('{{DATA}}/parquet/tpcds/catalog_returns.parquet', Parquet);
INSERT INTO tpcds.catalog_sales SELECT * FROM file('{{DATA}}/parquet/tpcds/catalog_sales.parquet', Parquet);
INSERT INTO tpcds.customer_address SELECT * FROM file('{{DATA}}/parquet/tpcds/customer_address.parquet', Parquet);
INSERT INTO tpcds.customer_demographics SELECT * FROM file('{{DATA}}/parquet/tpcds/customer_demographics.parquet', Parquet);
INSERT INTO tpcds.customer SELECT * FROM file('{{DATA}}/parquet/tpcds/customer.parquet', Parquet);
INSERT INTO tpcds.date_dim SELECT * FROM file('{{DATA}}/parquet/tpcds/date_dim.parquet', Parquet);
INSERT INTO tpcds.household_demographics SELECT * FROM file('{{DATA}}/parquet/tpcds/household_demographics.parquet', Parquet);
INSERT INTO tpcds.income_band SELECT * FROM file('{{DATA}}/parquet/tpcds/income_band.parquet', Parquet);
INSERT INTO tpcds.inventory SELECT * FROM file('{{DATA}}/parquet/tpcds/inventory.parquet', Parquet);
INSERT INTO tpcds.item SELECT * FROM file('{{DATA}}/parquet/tpcds/item.parquet', Parquet);
INSERT INTO tpcds.promotion SELECT * FROM file('{{DATA}}/parquet/tpcds/promotion.parquet', Parquet);
INSERT INTO tpcds.reason SELECT * FROM file('{{DATA}}/parquet/tpcds/reason.parquet', Parquet);
INSERT INTO tpcds.ship_mode SELECT * FROM file('{{DATA}}/parquet/tpcds/ship_mode.parquet', Parquet);
INSERT INTO tpcds.store_returns SELECT * FROM file('{{DATA}}/parquet/tpcds/store_returns.parquet', Parquet);
INSERT INTO tpcds.store_sales SELECT * FROM file('{{DATA}}/parquet/tpcds/store_sales.parquet', Parquet);
INSERT INTO tpcds.store SELECT * FROM file('{{DATA}}/parquet/tpcds/store.parquet', Parquet);
INSERT INTO tpcds.time_dim SELECT * FROM file('{{DATA}}/parquet/tpcds/time_dim.parquet', Parquet);
INSERT INTO tpcds.warehouse SELECT * FROM file('{{DATA}}/parquet/tpcds/warehouse.parquet', Parquet);
INSERT INTO tpcds.web_page SELECT * FROM file('{{DATA}}/parquet/tpcds/web_page.parquet', Parquet);
INSERT INTO tpcds.web_returns SELECT * FROM file('{{DATA}}/parquet/tpcds/web_returns.parquet', Parquet);
INSERT INTO tpcds.web_sales SELECT * FROM file('{{DATA}}/parquet/tpcds/web_sales.parquet', Parquet);
INSERT INTO tpcds.web_site SELECT * FROM file('{{DATA}}/parquet/tpcds/web_site.parquet', Parquet);
