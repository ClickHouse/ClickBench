-- TPCDS load for CedarDB.

INSERT INTO tpcds.call_center SELECT * FROM '{{DATA}}/parquet/tpcds/call_center.parquet';
INSERT INTO tpcds.catalog_page SELECT * FROM '{{DATA}}/parquet/tpcds/catalog_page.parquet';
INSERT INTO tpcds.catalog_returns SELECT * FROM '{{DATA}}/parquet/tpcds/catalog_returns.parquet';
INSERT INTO tpcds.catalog_sales SELECT * FROM '{{DATA}}/parquet/tpcds/catalog_sales.parquet';
INSERT INTO tpcds.customer_address SELECT * FROM '{{DATA}}/parquet/tpcds/customer_address.parquet';
INSERT INTO tpcds.customer_demographics SELECT * FROM '{{DATA}}/parquet/tpcds/customer_demographics.parquet';
INSERT INTO tpcds.customer SELECT * FROM '{{DATA}}/parquet/tpcds/customer.parquet';
INSERT INTO tpcds.date_dim SELECT * FROM '{{DATA}}/parquet/tpcds/date_dim.parquet';
INSERT INTO tpcds.household_demographics SELECT * FROM '{{DATA}}/parquet/tpcds/household_demographics.parquet';
INSERT INTO tpcds.income_band SELECT * FROM '{{DATA}}/parquet/tpcds/income_band.parquet';
INSERT INTO tpcds.inventory SELECT * FROM '{{DATA}}/parquet/tpcds/inventory.parquet';
INSERT INTO tpcds.item SELECT * FROM '{{DATA}}/parquet/tpcds/item.parquet';
INSERT INTO tpcds.promotion SELECT * FROM '{{DATA}}/parquet/tpcds/promotion.parquet';
INSERT INTO tpcds.reason SELECT * FROM '{{DATA}}/parquet/tpcds/reason.parquet';
INSERT INTO tpcds.ship_mode SELECT * FROM '{{DATA}}/parquet/tpcds/ship_mode.parquet';
INSERT INTO tpcds.store_returns SELECT * FROM '{{DATA}}/parquet/tpcds/store_returns.parquet';
INSERT INTO tpcds.store_sales SELECT * FROM '{{DATA}}/parquet/tpcds/store_sales.parquet';
INSERT INTO tpcds.store SELECT * FROM '{{DATA}}/parquet/tpcds/store.parquet';
INSERT INTO tpcds.time_dim SELECT * FROM '{{DATA}}/parquet/tpcds/time_dim.parquet';
INSERT INTO tpcds.warehouse SELECT * FROM '{{DATA}}/parquet/tpcds/warehouse.parquet';
INSERT INTO tpcds.web_page SELECT * FROM '{{DATA}}/parquet/tpcds/web_page.parquet';
INSERT INTO tpcds.web_returns SELECT * FROM '{{DATA}}/parquet/tpcds/web_returns.parquet';
INSERT INTO tpcds.web_sales SELECT * FROM '{{DATA}}/parquet/tpcds/web_sales.parquet';
INSERT INTO tpcds.web_site SELECT * FROM '{{DATA}}/parquet/tpcds/web_site.parquet';
