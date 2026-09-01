-- TPCDS load for DuckDB.

INSERT INTO call_center SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/call_center.parquet');
INSERT INTO catalog_page SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/catalog_page.parquet');
INSERT INTO catalog_returns SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/catalog_returns.parquet');
INSERT INTO catalog_sales SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/catalog_sales.parquet');
INSERT INTO customer_address SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/customer_address.parquet');
INSERT INTO customer_demographics SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/customer_demographics.parquet');
INSERT INTO customer SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/customer.parquet');
INSERT INTO date_dim SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/date_dim.parquet');
INSERT INTO household_demographics SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/household_demographics.parquet');
INSERT INTO income_band SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/income_band.parquet');
INSERT INTO inventory SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/inventory.parquet');
INSERT INTO item SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/item.parquet');
INSERT INTO promotion SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/promotion.parquet');
INSERT INTO reason SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/reason.parquet');
INSERT INTO ship_mode SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/ship_mode.parquet');
INSERT INTO store_returns SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/store_returns.parquet');
INSERT INTO store_sales SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/store_sales.parquet');
INSERT INTO store SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/store.parquet');
INSERT INTO time_dim SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/time_dim.parquet');
INSERT INTO warehouse SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/warehouse.parquet');
INSERT INTO web_page SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/web_page.parquet');
INSERT INTO web_returns SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/web_returns.parquet');
INSERT INTO web_sales SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/web_sales.parquet');
INSERT INTO web_site SELECT * FROM read_parquet('{{DATA}}/parquet/tpcds/web_site.parquet');
