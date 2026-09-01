-- TPCDS load for StarRocks.

INSERT INTO tpcds.call_center SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/call_center.parquet','format'='parquet');
INSERT INTO tpcds.catalog_page SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/catalog_page.parquet','format'='parquet');
INSERT INTO tpcds.catalog_returns SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/catalog_returns.parquet','format'='parquet');
INSERT INTO tpcds.catalog_sales SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/catalog_sales.parquet','format'='parquet');
INSERT INTO tpcds.customer_address SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/customer_address.parquet','format'='parquet');
INSERT INTO tpcds.customer_demographics SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/customer_demographics.parquet','format'='parquet');
INSERT INTO tpcds.customer SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/customer.parquet','format'='parquet');
INSERT INTO tpcds.date_dim SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/date_dim.parquet','format'='parquet');
INSERT INTO tpcds.household_demographics SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/household_demographics.parquet','format'='parquet');
INSERT INTO tpcds.income_band SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/income_band.parquet','format'='parquet');
INSERT INTO tpcds.inventory SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/inventory.parquet','format'='parquet');
INSERT INTO tpcds.item SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/item.parquet','format'='parquet');
INSERT INTO tpcds.promotion SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/promotion.parquet','format'='parquet');
INSERT INTO tpcds.reason SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/reason.parquet','format'='parquet');
INSERT INTO tpcds.ship_mode SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/ship_mode.parquet','format'='parquet');
INSERT INTO tpcds.store_returns SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/store_returns.parquet','format'='parquet');
INSERT INTO tpcds.store_sales SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/store_sales.parquet','format'='parquet');
INSERT INTO tpcds.store SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/store.parquet','format'='parquet');
INSERT INTO tpcds.time_dim SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/time_dim.parquet','format'='parquet');
INSERT INTO tpcds.warehouse SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/warehouse.parquet','format'='parquet');
INSERT INTO tpcds.web_page SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/web_page.parquet','format'='parquet');
INSERT INTO tpcds.web_returns SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/web_returns.parquet','format'='parquet');
INSERT INTO tpcds.web_sales SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/web_sales.parquet','format'='parquet');
INSERT INTO tpcds.web_site SELECT * FROM FILES('path'='{{DATA}}/parquet/tpcds/web_site.parquet','format'='parquet');
