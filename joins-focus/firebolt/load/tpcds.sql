-- TPCDS load for Firebolt Core.
--
-- A local Parquet path is not accepted by READ_PARQUET() (it resolves as an S3 URL), so each
-- table loads through an EXTERNAL TABLE over file:// and then an INSERT ... SELECT.
--
-- The external tables declare the PARQUET's own types -- DECIMAL(7,2) and DECIMAL(5,2), as the
-- spec and dsdgen have them. The target tables in ddl/ widen every decimal to (15,2), because
-- Firebolt does not widen decimal intermediates and SUM over a (7,2) column overflows past
-- 99,999. Firebolt will NOT implicitly assign numeric(7,2) to a numeric(15,2) column
-- ("numeric(7, 2) can't be assigned to column cc_gmt_offset of the type numeric(15, 2)"), so the
-- widening is an explicit CAST here, on the decimal columns only.

DROP TABLE IF EXISTS call_center_ext;
CREATE EXTERNAL TABLE call_center_ext
(
    cc_call_center_sk BIGINT NOT NULL,
    cc_call_center_id TEXT,
    cc_rec_start_date DATE,
    cc_rec_end_date DATE,
    cc_closed_date_sk INT,
    cc_open_date_sk INT,
    cc_name TEXT,
    cc_class TEXT,
    cc_employees BIGINT,
    cc_sq_ft BIGINT,
    cc_hours TEXT,
    cc_manager TEXT,
    cc_mkt_id BIGINT,
    cc_mkt_class TEXT,
    cc_mkt_desc TEXT,
    cc_market_manager TEXT,
    cc_division BIGINT,
    cc_division_name TEXT,
    cc_company BIGINT,
    cc_company_name TEXT,
    cc_street_number TEXT,
    cc_street_name TEXT,
    cc_street_type TEXT,
    cc_suite_number TEXT,
    cc_city TEXT,
    cc_county TEXT,
    cc_state TEXT,
    cc_zip TEXT,
    cc_country TEXT,
    cc_gmt_offset DECIMAL(5,2),
    cc_tax_percentage DECIMAL(5,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'call_center.parquet'
TYPE = PARQUET;
INSERT INTO call_center SELECT cc_call_center_sk, cc_call_center_id, cc_rec_start_date, cc_rec_end_date, cc_closed_date_sk, cc_open_date_sk, cc_name, cc_class, cc_employees, cc_sq_ft, cc_hours, cc_manager, cc_mkt_id, cc_mkt_class, cc_mkt_desc, cc_market_manager, cc_division, cc_division_name, cc_company, cc_company_name, cc_street_number, cc_street_name, cc_street_type, cc_suite_number, cc_city, cc_county, cc_state, cc_zip, cc_country, CAST(cc_gmt_offset AS DECIMAL(15,2)), CAST(cc_tax_percentage AS DECIMAL(15,2)) FROM call_center_ext;

DROP TABLE IF EXISTS catalog_page_ext;
CREATE EXTERNAL TABLE catalog_page_ext
(
    cp_catalog_page_sk BIGINT NOT NULL,
    cp_catalog_page_id TEXT,
    cp_start_date_sk INT,
    cp_end_date_sk INT,
    cp_department TEXT,
    cp_catalog_number BIGINT,
    cp_catalog_page_number BIGINT,
    cp_description TEXT,
    cp_type TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'catalog_page.parquet'
TYPE = PARQUET;
INSERT INTO catalog_page SELECT cp_catalog_page_sk, cp_catalog_page_id, cp_start_date_sk, cp_end_date_sk, cp_department, cp_catalog_number, cp_catalog_page_number, cp_description, cp_type FROM catalog_page_ext;

DROP TABLE IF EXISTS catalog_returns_ext;
CREATE EXTERNAL TABLE catalog_returns_ext
(
    cr_returned_date_sk INT,
    cr_returned_time_sk INT,
    cr_item_sk BIGINT NOT NULL,
    cr_refunded_customer_sk BIGINT,
    cr_refunded_cdemo_sk BIGINT,
    cr_refunded_hdemo_sk BIGINT,
    cr_refunded_addr_sk BIGINT,
    cr_returning_customer_sk BIGINT,
    cr_returning_cdemo_sk BIGINT,
    cr_returning_hdemo_sk BIGINT,
    cr_returning_addr_sk BIGINT,
    cr_call_center_sk BIGINT,
    cr_catalog_page_sk BIGINT,
    cr_ship_mode_sk BIGINT,
    cr_warehouse_sk BIGINT,
    cr_reason_sk BIGINT,
    cr_order_number BIGINT NOT NULL,
    cr_return_quantity BIGINT,
    cr_return_amount DECIMAL(7,2),
    cr_return_tax DECIMAL(7,2),
    cr_return_amt_inc_tax DECIMAL(7,2),
    cr_fee DECIMAL(7,2),
    cr_return_ship_cost DECIMAL(7,2),
    cr_refunded_cash DECIMAL(7,2),
    cr_reversed_charge DECIMAL(7,2),
    cr_store_credit DECIMAL(7,2),
    cr_net_loss DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'catalog_returns.parquet'
TYPE = PARQUET;
INSERT INTO catalog_returns SELECT cr_returned_date_sk, cr_returned_time_sk, cr_item_sk, cr_refunded_customer_sk, cr_refunded_cdemo_sk, cr_refunded_hdemo_sk, cr_refunded_addr_sk, cr_returning_customer_sk, cr_returning_cdemo_sk, cr_returning_hdemo_sk, cr_returning_addr_sk, cr_call_center_sk, cr_catalog_page_sk, cr_ship_mode_sk, cr_warehouse_sk, cr_reason_sk, cr_order_number, cr_return_quantity, CAST(cr_return_amount AS DECIMAL(15,2)), CAST(cr_return_tax AS DECIMAL(15,2)), CAST(cr_return_amt_inc_tax AS DECIMAL(15,2)), CAST(cr_fee AS DECIMAL(15,2)), CAST(cr_return_ship_cost AS DECIMAL(15,2)), CAST(cr_refunded_cash AS DECIMAL(15,2)), CAST(cr_reversed_charge AS DECIMAL(15,2)), CAST(cr_store_credit AS DECIMAL(15,2)), CAST(cr_net_loss AS DECIMAL(15,2)) FROM catalog_returns_ext;

DROP TABLE IF EXISTS catalog_sales_ext;
CREATE EXTERNAL TABLE catalog_sales_ext
(
    cs_sold_date_sk INT,
    cs_sold_time_sk INT,
    cs_ship_date_sk INT,
    cs_bill_customer_sk BIGINT,
    cs_bill_cdemo_sk BIGINT,
    cs_bill_hdemo_sk BIGINT,
    cs_bill_addr_sk BIGINT,
    cs_ship_customer_sk BIGINT,
    cs_ship_cdemo_sk BIGINT,
    cs_ship_hdemo_sk BIGINT,
    cs_ship_addr_sk BIGINT,
    cs_call_center_sk BIGINT,
    cs_catalog_page_sk BIGINT,
    cs_ship_mode_sk BIGINT,
    cs_warehouse_sk BIGINT,
    cs_item_sk BIGINT NOT NULL,
    cs_promo_sk BIGINT,
    cs_order_number BIGINT NOT NULL,
    cs_quantity BIGINT,
    cs_wholesale_cost DECIMAL(7,2),
    cs_list_price DECIMAL(7,2),
    cs_sales_price DECIMAL(7,2),
    cs_ext_discount_amt DECIMAL(7,2),
    cs_ext_sales_price DECIMAL(7,2),
    cs_ext_wholesale_cost DECIMAL(7,2),
    cs_ext_list_price DECIMAL(7,2),
    cs_ext_tax DECIMAL(7,2),
    cs_coupon_amt DECIMAL(7,2),
    cs_ext_ship_cost DECIMAL(7,2),
    cs_net_paid DECIMAL(7,2),
    cs_net_paid_inc_tax DECIMAL(7,2),
    cs_net_paid_inc_ship DECIMAL(7,2),
    cs_net_paid_inc_ship_tax DECIMAL(7,2),
    cs_net_profit DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'catalog_sales.parquet'
TYPE = PARQUET;
INSERT INTO catalog_sales SELECT cs_sold_date_sk, cs_sold_time_sk, cs_ship_date_sk, cs_bill_customer_sk, cs_bill_cdemo_sk, cs_bill_hdemo_sk, cs_bill_addr_sk, cs_ship_customer_sk, cs_ship_cdemo_sk, cs_ship_hdemo_sk, cs_ship_addr_sk, cs_call_center_sk, cs_catalog_page_sk, cs_ship_mode_sk, cs_warehouse_sk, cs_item_sk, cs_promo_sk, cs_order_number, cs_quantity, CAST(cs_wholesale_cost AS DECIMAL(15,2)), CAST(cs_list_price AS DECIMAL(15,2)), CAST(cs_sales_price AS DECIMAL(15,2)), CAST(cs_ext_discount_amt AS DECIMAL(15,2)), CAST(cs_ext_sales_price AS DECIMAL(15,2)), CAST(cs_ext_wholesale_cost AS DECIMAL(15,2)), CAST(cs_ext_list_price AS DECIMAL(15,2)), CAST(cs_ext_tax AS DECIMAL(15,2)), CAST(cs_coupon_amt AS DECIMAL(15,2)), CAST(cs_ext_ship_cost AS DECIMAL(15,2)), CAST(cs_net_paid AS DECIMAL(15,2)), CAST(cs_net_paid_inc_tax AS DECIMAL(15,2)), CAST(cs_net_paid_inc_ship AS DECIMAL(15,2)), CAST(cs_net_paid_inc_ship_tax AS DECIMAL(15,2)), CAST(cs_net_profit AS DECIMAL(15,2)) FROM catalog_sales_ext;

DROP TABLE IF EXISTS customer_address_ext;
CREATE EXTERNAL TABLE customer_address_ext
(
    ca_address_sk BIGINT NOT NULL,
    ca_address_id TEXT,
    ca_street_number TEXT,
    ca_street_name TEXT,
    ca_street_type TEXT,
    ca_suite_number TEXT,
    ca_city TEXT,
    ca_county TEXT,
    ca_state TEXT,
    ca_zip TEXT,
    ca_country TEXT,
    ca_gmt_offset DECIMAL(5,2),
    ca_location_type TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'customer_address.parquet'
TYPE = PARQUET;
INSERT INTO customer_address SELECT ca_address_sk, ca_address_id, ca_street_number, ca_street_name, ca_street_type, ca_suite_number, ca_city, ca_county, ca_state, ca_zip, ca_country, CAST(ca_gmt_offset AS DECIMAL(15,2)), ca_location_type FROM customer_address_ext;

DROP TABLE IF EXISTS customer_demographics_ext;
CREATE EXTERNAL TABLE customer_demographics_ext
(
    cd_demo_sk BIGINT NOT NULL,
    cd_gender TEXT,
    cd_marital_status TEXT,
    cd_education_status TEXT,
    cd_purchase_estimate BIGINT,
    cd_credit_rating TEXT,
    cd_dep_count BIGINT,
    cd_dep_employed_count BIGINT,
    cd_dep_college_count BIGINT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'customer_demographics.parquet'
TYPE = PARQUET;
INSERT INTO customer_demographics SELECT cd_demo_sk, cd_gender, cd_marital_status, cd_education_status, cd_purchase_estimate, cd_credit_rating, cd_dep_count, cd_dep_employed_count, cd_dep_college_count FROM customer_demographics_ext;

DROP TABLE IF EXISTS customer_ext;
CREATE EXTERNAL TABLE customer_ext
(
    c_customer_sk BIGINT NOT NULL,
    c_customer_id TEXT,
    c_current_cdemo_sk BIGINT,
    c_current_hdemo_sk BIGINT,
    c_current_addr_sk BIGINT,
    c_first_shipto_date_sk INT,
    c_first_sales_date_sk INT,
    c_salutation TEXT,
    c_first_name TEXT,
    c_last_name TEXT,
    c_preferred_cust_flag TEXT,
    c_birth_day BIGINT,
    c_birth_month BIGINT,
    c_birth_year BIGINT,
    c_birth_country TEXT,
    c_login TEXT,
    c_email_address TEXT,
    c_last_review_date_sk INT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'customer.parquet'
TYPE = PARQUET;
INSERT INTO customer SELECT c_customer_sk, c_customer_id, c_current_cdemo_sk, c_current_hdemo_sk, c_current_addr_sk, c_first_shipto_date_sk, c_first_sales_date_sk, c_salutation, c_first_name, c_last_name, c_preferred_cust_flag, c_birth_day, c_birth_month, c_birth_year, c_birth_country, c_login, c_email_address, c_last_review_date_sk FROM customer_ext;

DROP TABLE IF EXISTS date_dim_ext;
CREATE EXTERNAL TABLE date_dim_ext
(
    d_date_sk INT NOT NULL,
    d_date_id TEXT,
    d_date DATE NOT NULL,
    d_month_seq BIGINT,
    d_week_seq BIGINT,
    d_quarter_seq BIGINT,
    d_year BIGINT,
    d_dow BIGINT,
    d_moy BIGINT,
    d_dom BIGINT,
    d_qoy BIGINT,
    d_fy_year BIGINT,
    d_fy_quarter_seq BIGINT,
    d_fy_week_seq BIGINT,
    d_day_name TEXT,
    d_quarter_name TEXT,
    d_holiday TEXT,
    d_weekend TEXT,
    d_following_holiday TEXT,
    d_first_dom BIGINT,
    d_last_dom BIGINT,
    d_same_day_ly BIGINT,
    d_same_day_lq BIGINT,
    d_current_day TEXT,
    d_current_week TEXT,
    d_current_month TEXT,
    d_current_quarter TEXT,
    d_current_year TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'date_dim.parquet'
TYPE = PARQUET;
INSERT INTO date_dim SELECT d_date_sk, d_date_id, d_date, d_month_seq, d_week_seq, d_quarter_seq, d_year, d_dow, d_moy, d_dom, d_qoy, d_fy_year, d_fy_quarter_seq, d_fy_week_seq, d_day_name, d_quarter_name, d_holiday, d_weekend, d_following_holiday, d_first_dom, d_last_dom, d_same_day_ly, d_same_day_lq, d_current_day, d_current_week, d_current_month, d_current_quarter, d_current_year FROM date_dim_ext;

DROP TABLE IF EXISTS household_demographics_ext;
CREATE EXTERNAL TABLE household_demographics_ext
(
    hd_demo_sk BIGINT NOT NULL,
    hd_income_band_sk BIGINT,
    hd_buy_potential TEXT,
    hd_dep_count BIGINT,
    hd_vehicle_count BIGINT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'household_demographics.parquet'
TYPE = PARQUET;
INSERT INTO household_demographics SELECT hd_demo_sk, hd_income_band_sk, hd_buy_potential, hd_dep_count, hd_vehicle_count FROM household_demographics_ext;

DROP TABLE IF EXISTS income_band_ext;
CREATE EXTERNAL TABLE income_band_ext
(
    ib_income_band_sk BIGINT NOT NULL,
    ib_lower_bound BIGINT,
    ib_upper_bound BIGINT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'income_band.parquet'
TYPE = PARQUET;
INSERT INTO income_band SELECT ib_income_band_sk, ib_lower_bound, ib_upper_bound FROM income_band_ext;

DROP TABLE IF EXISTS inventory_ext;
CREATE EXTERNAL TABLE inventory_ext
(
    inv_date_sk INT NOT NULL,
    inv_item_sk BIGINT NOT NULL,
    inv_warehouse_sk BIGINT NOT NULL,
    inv_quantity_on_hand BIGINT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'inventory.parquet'
TYPE = PARQUET;
INSERT INTO inventory SELECT inv_date_sk, inv_item_sk, inv_warehouse_sk, inv_quantity_on_hand FROM inventory_ext;

DROP TABLE IF EXISTS item_ext;
CREATE EXTERNAL TABLE item_ext
(
    i_item_sk BIGINT NOT NULL,
    i_item_id TEXT,
    i_rec_start_date DATE,
    i_rec_end_date DATE,
    i_item_desc TEXT,
    i_current_price DECIMAL(7,2),
    i_wholesale_cost DECIMAL(7,2),
    i_brand_id BIGINT,
    i_brand TEXT,
    i_class_id BIGINT,
    i_class TEXT,
    i_category_id BIGINT,
    i_category TEXT,
    i_manufact_id BIGINT,
    i_manufact TEXT,
    i_size TEXT,
    i_formulation TEXT,
    i_color TEXT,
    i_units TEXT,
    i_container TEXT,
    i_manager_id BIGINT,
    i_product_name TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'item.parquet'
TYPE = PARQUET;
INSERT INTO item SELECT i_item_sk, i_item_id, i_rec_start_date, i_rec_end_date, i_item_desc, CAST(i_current_price AS DECIMAL(15,2)), CAST(i_wholesale_cost AS DECIMAL(15,2)), i_brand_id, i_brand, i_class_id, i_class, i_category_id, i_category, i_manufact_id, i_manufact, i_size, i_formulation, i_color, i_units, i_container, i_manager_id, i_product_name FROM item_ext;

DROP TABLE IF EXISTS promotion_ext;
CREATE EXTERNAL TABLE promotion_ext
(
    p_promo_sk BIGINT NOT NULL,
    p_promo_id TEXT,
    p_start_date_sk INT,
    p_end_date_sk INT,
    p_item_sk BIGINT,
    p_cost DECIMAL(15,2),
    p_response_target BIGINT,
    p_promo_name TEXT,
    p_channel_dmail TEXT,
    p_channel_email TEXT,
    p_channel_catalog TEXT,
    p_channel_tv TEXT,
    p_channel_radio TEXT,
    p_channel_press TEXT,
    p_channel_event TEXT,
    p_channel_demo TEXT,
    p_channel_details TEXT,
    p_purpose TEXT,
    p_discount_active TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'promotion.parquet'
TYPE = PARQUET;
INSERT INTO promotion SELECT p_promo_sk, p_promo_id, p_start_date_sk, p_end_date_sk, p_item_sk, CAST(p_cost AS DECIMAL(15,2)), p_response_target, p_promo_name, p_channel_dmail, p_channel_email, p_channel_catalog, p_channel_tv, p_channel_radio, p_channel_press, p_channel_event, p_channel_demo, p_channel_details, p_purpose, p_discount_active FROM promotion_ext;

DROP TABLE IF EXISTS reason_ext;
CREATE EXTERNAL TABLE reason_ext
(
    r_reason_sk BIGINT NOT NULL,
    r_reason_id TEXT,
    r_reason_desc TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'reason.parquet'
TYPE = PARQUET;
INSERT INTO reason SELECT r_reason_sk, r_reason_id, r_reason_desc FROM reason_ext;

DROP TABLE IF EXISTS ship_mode_ext;
CREATE EXTERNAL TABLE ship_mode_ext
(
    sm_ship_mode_sk BIGINT NOT NULL,
    sm_ship_mode_id TEXT,
    sm_type TEXT,
    sm_code TEXT,
    sm_carrier TEXT,
    sm_contract TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'ship_mode.parquet'
TYPE = PARQUET;
INSERT INTO ship_mode SELECT sm_ship_mode_sk, sm_ship_mode_id, sm_type, sm_code, sm_carrier, sm_contract FROM ship_mode_ext;

DROP TABLE IF EXISTS store_returns_ext;
CREATE EXTERNAL TABLE store_returns_ext
(
    sr_returned_date_sk INT,
    sr_return_time_sk INT,
    sr_item_sk BIGINT NOT NULL,
    sr_customer_sk BIGINT,
    sr_cdemo_sk BIGINT,
    sr_hdemo_sk BIGINT,
    sr_addr_sk BIGINT,
    sr_store_sk BIGINT,
    sr_reason_sk BIGINT,
    sr_ticket_number BIGINT NOT NULL,
    sr_return_quantity BIGINT,
    sr_return_amt DECIMAL(7,2),
    sr_return_tax DECIMAL(7,2),
    sr_return_amt_inc_tax DECIMAL(7,2),
    sr_fee DECIMAL(7,2),
    sr_return_ship_cost DECIMAL(7,2),
    sr_refunded_cash DECIMAL(7,2),
    sr_reversed_charge DECIMAL(7,2),
    sr_store_credit DECIMAL(7,2),
    sr_net_loss DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'store_returns.parquet'
TYPE = PARQUET;
INSERT INTO store_returns SELECT sr_returned_date_sk, sr_return_time_sk, sr_item_sk, sr_customer_sk, sr_cdemo_sk, sr_hdemo_sk, sr_addr_sk, sr_store_sk, sr_reason_sk, sr_ticket_number, sr_return_quantity, CAST(sr_return_amt AS DECIMAL(15,2)), CAST(sr_return_tax AS DECIMAL(15,2)), CAST(sr_return_amt_inc_tax AS DECIMAL(15,2)), CAST(sr_fee AS DECIMAL(15,2)), CAST(sr_return_ship_cost AS DECIMAL(15,2)), CAST(sr_refunded_cash AS DECIMAL(15,2)), CAST(sr_reversed_charge AS DECIMAL(15,2)), CAST(sr_store_credit AS DECIMAL(15,2)), CAST(sr_net_loss AS DECIMAL(15,2)) FROM store_returns_ext;

DROP TABLE IF EXISTS store_sales_ext;
CREATE EXTERNAL TABLE store_sales_ext
(
    ss_sold_date_sk INT,
    ss_sold_time_sk INT,
    ss_item_sk BIGINT NOT NULL,
    ss_customer_sk BIGINT,
    ss_cdemo_sk BIGINT,
    ss_hdemo_sk BIGINT,
    ss_addr_sk BIGINT,
    ss_store_sk BIGINT,
    ss_promo_sk BIGINT,
    ss_ticket_number BIGINT NOT NULL,
    ss_quantity BIGINT,
    ss_wholesale_cost DECIMAL(7,2),
    ss_list_price DECIMAL(7,2),
    ss_sales_price DECIMAL(7,2),
    ss_ext_discount_amt DECIMAL(7,2),
    ss_ext_sales_price DECIMAL(7,2),
    ss_ext_wholesale_cost DECIMAL(7,2),
    ss_ext_list_price DECIMAL(7,2),
    ss_ext_tax DECIMAL(7,2),
    ss_coupon_amt DECIMAL(7,2),
    ss_net_paid DECIMAL(7,2),
    ss_net_paid_inc_tax DECIMAL(7,2),
    ss_net_profit DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'store_sales.parquet'
TYPE = PARQUET;
INSERT INTO store_sales SELECT ss_sold_date_sk, ss_sold_time_sk, ss_item_sk, ss_customer_sk, ss_cdemo_sk, ss_hdemo_sk, ss_addr_sk, ss_store_sk, ss_promo_sk, ss_ticket_number, ss_quantity, CAST(ss_wholesale_cost AS DECIMAL(15,2)), CAST(ss_list_price AS DECIMAL(15,2)), CAST(ss_sales_price AS DECIMAL(15,2)), CAST(ss_ext_discount_amt AS DECIMAL(15,2)), CAST(ss_ext_sales_price AS DECIMAL(15,2)), CAST(ss_ext_wholesale_cost AS DECIMAL(15,2)), CAST(ss_ext_list_price AS DECIMAL(15,2)), CAST(ss_ext_tax AS DECIMAL(15,2)), CAST(ss_coupon_amt AS DECIMAL(15,2)), CAST(ss_net_paid AS DECIMAL(15,2)), CAST(ss_net_paid_inc_tax AS DECIMAL(15,2)), CAST(ss_net_profit AS DECIMAL(15,2)) FROM store_sales_ext;

DROP TABLE IF EXISTS store_ext;
CREATE EXTERNAL TABLE store_ext
(
    s_store_sk BIGINT NOT NULL,
    s_store_id TEXT,
    s_rec_start_date DATE,
    s_rec_end_date DATE,
    s_closed_date_sk INT,
    s_store_name TEXT,
    s_number_employees BIGINT,
    s_floor_space BIGINT,
    s_hours TEXT,
    s_manager TEXT,
    s_market_id BIGINT,
    s_geography_class TEXT,
    s_market_desc TEXT,
    s_market_manager TEXT,
    s_division_id BIGINT,
    s_division_name TEXT,
    s_company_id BIGINT,
    s_company_name TEXT,
    s_street_number TEXT,
    s_street_name TEXT,
    s_street_type TEXT,
    s_suite_number TEXT,
    s_city TEXT,
    s_county TEXT,
    s_state TEXT,
    s_zip TEXT,
    s_country TEXT,
    s_gmt_offset DECIMAL(5,2),
    s_tax_percentage DECIMAL(5,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'store.parquet'
TYPE = PARQUET;
INSERT INTO store SELECT s_store_sk, s_store_id, s_rec_start_date, s_rec_end_date, s_closed_date_sk, s_store_name, s_number_employees, s_floor_space, s_hours, s_manager, s_market_id, s_geography_class, s_market_desc, s_market_manager, s_division_id, s_division_name, s_company_id, s_company_name, s_street_number, s_street_name, s_street_type, s_suite_number, s_city, s_county, s_state, s_zip, s_country, CAST(s_gmt_offset AS DECIMAL(15,2)), CAST(s_tax_percentage AS DECIMAL(15,2)) FROM store_ext;

DROP TABLE IF EXISTS time_dim_ext;
CREATE EXTERNAL TABLE time_dim_ext
(
    t_time_sk INT NOT NULL,
    t_time_id TEXT,
    t_time BIGINT NOT NULL,
    t_hour BIGINT,
    t_minute BIGINT,
    t_second BIGINT,
    t_am_pm TEXT,
    t_shift TEXT,
    t_sub_shift TEXT,
    t_meal_time TEXT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'time_dim.parquet'
TYPE = PARQUET;
INSERT INTO time_dim SELECT t_time_sk, t_time_id, t_time, t_hour, t_minute, t_second, t_am_pm, t_shift, t_sub_shift, t_meal_time FROM time_dim_ext;

DROP TABLE IF EXISTS warehouse_ext;
CREATE EXTERNAL TABLE warehouse_ext
(
    w_warehouse_sk BIGINT NOT NULL,
    w_warehouse_id TEXT,
    w_warehouse_name TEXT,
    w_warehouse_sq_ft BIGINT,
    w_street_number TEXT,
    w_street_name TEXT,
    w_street_type TEXT,
    w_suite_number TEXT,
    w_city TEXT,
    w_county TEXT,
    w_state TEXT,
    w_zip TEXT,
    w_country TEXT,
    w_gmt_offset DECIMAL(5,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'warehouse.parquet'
TYPE = PARQUET;
INSERT INTO warehouse SELECT w_warehouse_sk, w_warehouse_id, w_warehouse_name, w_warehouse_sq_ft, w_street_number, w_street_name, w_street_type, w_suite_number, w_city, w_county, w_state, w_zip, w_country, CAST(w_gmt_offset AS DECIMAL(15,2)) FROM warehouse_ext;

DROP TABLE IF EXISTS web_page_ext;
CREATE EXTERNAL TABLE web_page_ext
(
    wp_web_page_sk BIGINT NOT NULL,
    wp_web_page_id TEXT,
    wp_rec_start_date DATE,
    wp_rec_end_date DATE,
    wp_creation_date_sk INT,
    wp_access_date_sk INT,
    wp_autogen_flag TEXT,
    wp_customer_sk BIGINT,
    wp_url TEXT,
    wp_type TEXT,
    wp_char_count BIGINT,
    wp_link_count BIGINT,
    wp_image_count BIGINT,
    wp_max_ad_count BIGINT
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'web_page.parquet'
TYPE = PARQUET;
INSERT INTO web_page SELECT wp_web_page_sk, wp_web_page_id, wp_rec_start_date, wp_rec_end_date, wp_creation_date_sk, wp_access_date_sk, wp_autogen_flag, wp_customer_sk, wp_url, wp_type, wp_char_count, wp_link_count, wp_image_count, wp_max_ad_count FROM web_page_ext;

DROP TABLE IF EXISTS web_returns_ext;
CREATE EXTERNAL TABLE web_returns_ext
(
    wr_returned_date_sk INT,
    wr_returned_time_sk INT,
    wr_item_sk BIGINT NOT NULL,
    wr_refunded_customer_sk BIGINT,
    wr_refunded_cdemo_sk BIGINT,
    wr_refunded_hdemo_sk BIGINT,
    wr_refunded_addr_sk BIGINT,
    wr_returning_customer_sk BIGINT,
    wr_returning_cdemo_sk BIGINT,
    wr_returning_hdemo_sk BIGINT,
    wr_returning_addr_sk BIGINT,
    wr_web_page_sk BIGINT,
    wr_reason_sk BIGINT,
    wr_order_number BIGINT NOT NULL,
    wr_return_quantity BIGINT,
    wr_return_amt DECIMAL(7,2),
    wr_return_tax DECIMAL(7,2),
    wr_return_amt_inc_tax DECIMAL(7,2),
    wr_fee DECIMAL(7,2),
    wr_return_ship_cost DECIMAL(7,2),
    wr_refunded_cash DECIMAL(7,2),
    wr_reversed_charge DECIMAL(7,2),
    wr_account_credit DECIMAL(7,2),
    wr_net_loss DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'web_returns.parquet'
TYPE = PARQUET;
INSERT INTO web_returns SELECT wr_returned_date_sk, wr_returned_time_sk, wr_item_sk, wr_refunded_customer_sk, wr_refunded_cdemo_sk, wr_refunded_hdemo_sk, wr_refunded_addr_sk, wr_returning_customer_sk, wr_returning_cdemo_sk, wr_returning_hdemo_sk, wr_returning_addr_sk, wr_web_page_sk, wr_reason_sk, wr_order_number, wr_return_quantity, CAST(wr_return_amt AS DECIMAL(15,2)), CAST(wr_return_tax AS DECIMAL(15,2)), CAST(wr_return_amt_inc_tax AS DECIMAL(15,2)), CAST(wr_fee AS DECIMAL(15,2)), CAST(wr_return_ship_cost AS DECIMAL(15,2)), CAST(wr_refunded_cash AS DECIMAL(15,2)), CAST(wr_reversed_charge AS DECIMAL(15,2)), CAST(wr_account_credit AS DECIMAL(15,2)), CAST(wr_net_loss AS DECIMAL(15,2)) FROM web_returns_ext;

DROP TABLE IF EXISTS web_sales_ext;
CREATE EXTERNAL TABLE web_sales_ext
(
    ws_sold_date_sk INT,
    ws_sold_time_sk INT,
    ws_ship_date_sk INT,
    ws_item_sk BIGINT NOT NULL,
    ws_bill_customer_sk BIGINT,
    ws_bill_cdemo_sk BIGINT,
    ws_bill_hdemo_sk BIGINT,
    ws_bill_addr_sk BIGINT,
    ws_ship_customer_sk BIGINT,
    ws_ship_cdemo_sk BIGINT,
    ws_ship_hdemo_sk BIGINT,
    ws_ship_addr_sk BIGINT,
    ws_web_page_sk BIGINT,
    ws_web_site_sk BIGINT,
    ws_ship_mode_sk BIGINT,
    ws_warehouse_sk BIGINT,
    ws_promo_sk BIGINT,
    ws_order_number BIGINT NOT NULL,
    ws_quantity BIGINT,
    ws_wholesale_cost DECIMAL(7,2),
    ws_list_price DECIMAL(7,2),
    ws_sales_price DECIMAL(7,2),
    ws_ext_discount_amt DECIMAL(7,2),
    ws_ext_sales_price DECIMAL(7,2),
    ws_ext_wholesale_cost DECIMAL(7,2),
    ws_ext_list_price DECIMAL(7,2),
    ws_ext_tax DECIMAL(7,2),
    ws_coupon_amt DECIMAL(7,2),
    ws_ext_ship_cost DECIMAL(7,2),
    ws_net_paid DECIMAL(7,2),
    ws_net_paid_inc_tax DECIMAL(7,2),
    ws_net_paid_inc_ship DECIMAL(7,2),
    ws_net_paid_inc_ship_tax DECIMAL(7,2),
    ws_net_profit DECIMAL(7,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'web_sales.parquet'
TYPE = PARQUET;
INSERT INTO web_sales SELECT ws_sold_date_sk, ws_sold_time_sk, ws_ship_date_sk, ws_item_sk, ws_bill_customer_sk, ws_bill_cdemo_sk, ws_bill_hdemo_sk, ws_bill_addr_sk, ws_ship_customer_sk, ws_ship_cdemo_sk, ws_ship_hdemo_sk, ws_ship_addr_sk, ws_web_page_sk, ws_web_site_sk, ws_ship_mode_sk, ws_warehouse_sk, ws_promo_sk, ws_order_number, ws_quantity, CAST(ws_wholesale_cost AS DECIMAL(15,2)), CAST(ws_list_price AS DECIMAL(15,2)), CAST(ws_sales_price AS DECIMAL(15,2)), CAST(ws_ext_discount_amt AS DECIMAL(15,2)), CAST(ws_ext_sales_price AS DECIMAL(15,2)), CAST(ws_ext_wholesale_cost AS DECIMAL(15,2)), CAST(ws_ext_list_price AS DECIMAL(15,2)), CAST(ws_ext_tax AS DECIMAL(15,2)), CAST(ws_coupon_amt AS DECIMAL(15,2)), CAST(ws_ext_ship_cost AS DECIMAL(15,2)), CAST(ws_net_paid AS DECIMAL(15,2)), CAST(ws_net_paid_inc_tax AS DECIMAL(15,2)), CAST(ws_net_paid_inc_ship AS DECIMAL(15,2)), CAST(ws_net_paid_inc_ship_tax AS DECIMAL(15,2)), CAST(ws_net_profit AS DECIMAL(15,2)) FROM web_sales_ext;

DROP TABLE IF EXISTS web_site_ext;
CREATE EXTERNAL TABLE web_site_ext
(
    web_site_sk BIGINT NOT NULL,
    web_site_id TEXT,
    web_rec_start_date DATE,
    web_rec_end_date DATE,
    web_name TEXT,
    web_open_date_sk INT,
    web_close_date_sk INT,
    web_class TEXT,
    web_manager TEXT,
    web_mkt_id BIGINT,
    web_mkt_class TEXT,
    web_mkt_desc TEXT,
    web_market_manager TEXT,
    web_company_id BIGINT,
    web_company_name TEXT,
    web_street_number TEXT,
    web_street_name TEXT,
    web_street_type TEXT,
    web_suite_number TEXT,
    web_city TEXT,
    web_county TEXT,
    web_state TEXT,
    web_zip TEXT,
    web_country TEXT,
    web_gmt_offset DECIMAL(5,2),
    web_tax_percentage DECIMAL(5,2)
)
URL = 'file://{{DATA}}/parquet/tpcds/'
OBJECT_PATTERN = 'web_site.parquet'
TYPE = PARQUET;
INSERT INTO web_site SELECT web_site_sk, web_site_id, web_rec_start_date, web_rec_end_date, web_name, web_open_date_sk, web_close_date_sk, web_class, web_manager, web_mkt_id, web_mkt_class, web_mkt_desc, web_market_manager, web_company_id, web_company_name, web_street_number, web_street_name, web_street_type, web_suite_number, web_city, web_county, web_state, web_zip, web_country, CAST(web_gmt_offset AS DECIMAL(15,2)), CAST(web_tax_percentage AS DECIMAL(15,2)) FROM web_site_ext;

-- No statistics step: Firebolt Core does not implement ANALYZE in any form, so this
-- system runs without collected statistics. That is a real difference from the other
-- six, not an omission here.
