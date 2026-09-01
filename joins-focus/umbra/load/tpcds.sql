-- TPCDS load for Umbra. Umbra has no Parquet reader, so it loads the CSV
-- export. NULL is \N there, which is how an empty string stays distinguishable
-- from a NULL.

COPY tpcds.call_center FROM '{{DATA}}/csv/tpcds/call_center.csv' (FORMAT csv, NULL '\N');
COPY tpcds.catalog_page FROM '{{DATA}}/csv/tpcds/catalog_page.csv' (FORMAT csv, NULL '\N');
COPY tpcds.catalog_returns FROM '{{DATA}}/csv/tpcds/catalog_returns.csv' (FORMAT csv, NULL '\N');
COPY tpcds.catalog_sales FROM '{{DATA}}/csv/tpcds/catalog_sales.csv' (FORMAT csv, NULL '\N');
COPY tpcds.customer_address FROM '{{DATA}}/csv/tpcds/customer_address.csv' (FORMAT csv, NULL '\N');
COPY tpcds.customer_demographics FROM '{{DATA}}/csv/tpcds/customer_demographics.csv' (FORMAT csv, NULL '\N');
COPY tpcds.customer FROM '{{DATA}}/csv/tpcds/customer.csv' (FORMAT csv, NULL '\N');
COPY tpcds.date_dim FROM '{{DATA}}/csv/tpcds/date_dim.csv' (FORMAT csv, NULL '\N');
COPY tpcds.household_demographics FROM '{{DATA}}/csv/tpcds/household_demographics.csv' (FORMAT csv, NULL '\N');
COPY tpcds.income_band FROM '{{DATA}}/csv/tpcds/income_band.csv' (FORMAT csv, NULL '\N');
COPY tpcds.inventory FROM '{{DATA}}/csv/tpcds/inventory.csv' (FORMAT csv, NULL '\N');
COPY tpcds.item FROM '{{DATA}}/csv/tpcds/item.csv' (FORMAT csv, NULL '\N');
COPY tpcds.promotion FROM '{{DATA}}/csv/tpcds/promotion.csv' (FORMAT csv, NULL '\N');
COPY tpcds.reason FROM '{{DATA}}/csv/tpcds/reason.csv' (FORMAT csv, NULL '\N');
COPY tpcds.ship_mode FROM '{{DATA}}/csv/tpcds/ship_mode.csv' (FORMAT csv, NULL '\N');
COPY tpcds.store_returns FROM '{{DATA}}/csv/tpcds/store_returns.csv' (FORMAT csv, NULL '\N');
COPY tpcds.store_sales FROM '{{DATA}}/csv/tpcds/store_sales.csv' (FORMAT csv, NULL '\N');
COPY tpcds.store FROM '{{DATA}}/csv/tpcds/store.csv' (FORMAT csv, NULL '\N');
COPY tpcds.time_dim FROM '{{DATA}}/csv/tpcds/time_dim.csv' (FORMAT csv, NULL '\N');
COPY tpcds.warehouse FROM '{{DATA}}/csv/tpcds/warehouse.csv' (FORMAT csv, NULL '\N');
COPY tpcds.web_page FROM '{{DATA}}/csv/tpcds/web_page.csv' (FORMAT csv, NULL '\N');
COPY tpcds.web_returns FROM '{{DATA}}/csv/tpcds/web_returns.csv' (FORMAT csv, NULL '\N');
COPY tpcds.web_sales FROM '{{DATA}}/csv/tpcds/web_sales.csv' (FORMAT csv, NULL '\N');
COPY tpcds.web_site FROM '{{DATA}}/csv/tpcds/web_site.csv' (FORMAT csv, NULL '\N');
