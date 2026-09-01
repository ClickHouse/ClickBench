-- DELIBERATE DEVIATION, Firebolt only: every DECIMAL is widened to (15,2).
--
-- The spec declares these columns DECIMAL(7,2) (and DECIMAL(5,2) for the offsets), and the
-- other six systems use exactly that. But Firebolt Core does not widen decimal intermediates:
-- SUM over a DECIMAL(7,2) column yields DECIMAL(7,2), whose integer part holds five digits, so
-- it overflows past 99,999 --
--     Decimal math overflow. Result value: 2834241. The maximum allowed precision for the
--     expression is: 5 (precision - scale). Increase the precision of the result.
-- That failed 31 of the 103 TPC-DS queries, plus 2 more with "Operations between decimals with
-- different precision and scale is not supported" from mixing (7,2) with (5,2).
--
-- Every other engine here promotes the accumulator when summing an exact numeric -- the SQL
-- standard leaves the SUM result type implementation-defined precisely so it can be widened --
-- so declaring (15,2) makes Firebolt behave as they already do, rather than changing what the
-- queries compute. TPC also permits a datatype of greater precision than the specified minimum,
-- whereas editing query text is not permitted, which is why this is fixed here and not there.
--
-- Consequence: Firebolt's data_size is not directly comparable with the other six, since it
-- stores 15-digit decimals where they store 7. Its load/ external tables still declare (7,2),
-- matching the Parquet exactly; the INSERT widens on the way in.

-- TPCDS schema for Firebolt. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE DATABASE IF NOT EXISTS tpcds;

DROP TABLE IF EXISTS web_site;
DROP TABLE IF EXISTS web_sales;
DROP TABLE IF EXISTS web_returns;
DROP TABLE IF EXISTS web_page;
DROP TABLE IF EXISTS warehouse;
DROP TABLE IF EXISTS time_dim;
DROP TABLE IF EXISTS store;
DROP TABLE IF EXISTS store_sales;
DROP TABLE IF EXISTS store_returns;
DROP TABLE IF EXISTS ship_mode;
DROP TABLE IF EXISTS reason;
DROP TABLE IF EXISTS promotion;
DROP TABLE IF EXISTS item;
DROP TABLE IF EXISTS inventory;
DROP TABLE IF EXISTS income_band;
DROP TABLE IF EXISTS household_demographics;
DROP TABLE IF EXISTS date_dim;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS customer_demographics;
DROP TABLE IF EXISTS customer_address;
DROP TABLE IF EXISTS catalog_sales;
DROP TABLE IF EXISTS catalog_returns;
DROP TABLE IF EXISTS catalog_page;
DROP TABLE IF EXISTS call_center;

CREATE TABLE call_center (
    cc_call_center_sk BIGINT NOT NULL,
    cc_call_center_id TEXT NOT NULL,
    cc_rec_start_date DATE,
    cc_rec_end_date   DATE,
    cc_closed_date_sk INT,
    cc_open_date_sk   INT,
    cc_name           TEXT,
    cc_class          TEXT,
    cc_employees      BIGINT,
    cc_sq_ft          BIGINT,
    cc_hours          TEXT,
    cc_manager        TEXT,
    cc_mkt_id         BIGINT,
    cc_mkt_class      TEXT,
    cc_mkt_desc       TEXT,
    cc_market_manager TEXT,
    cc_division       BIGINT,
    cc_division_name  TEXT,
    cc_company        BIGINT,
    cc_company_name   TEXT,
    cc_street_number  TEXT,
    cc_street_name    TEXT,
    cc_street_type    TEXT,
    cc_suite_number   TEXT,
    cc_city           TEXT,
    cc_county         TEXT,
    cc_state          TEXT,
    cc_zip            TEXT,
    cc_country        TEXT,
    cc_gmt_offset     DECIMAL(15,2),
    cc_tax_percentage DECIMAL(15,2))
PRIMARY INDEX cc_call_center_sk;

CREATE TABLE catalog_page (
    cp_catalog_page_sk     BIGINT NOT NULL,
    cp_catalog_page_id     TEXT NOT NULL,
    cp_start_date_sk       INT,
    cp_end_date_sk         INT,
    cp_department          TEXT,
    cp_catalog_number      BIGINT,
    cp_catalog_page_number BIGINT,
    cp_description         TEXT,
    cp_type                TEXT)
PRIMARY INDEX cp_catalog_page_sk;

CREATE TABLE catalog_returns (
    cr_returned_date_sk      INT,
    cr_returned_time_sk      INT,
    cr_item_sk               BIGINT NOT NULL,
    cr_refunded_customer_sk  BIGINT,
    cr_refunded_cdemo_sk     BIGINT,
    cr_refunded_hdemo_sk     BIGINT,
    cr_refunded_addr_sk      BIGINT,
    cr_returning_customer_sk BIGINT,
    cr_returning_cdemo_sk    BIGINT,
    cr_returning_hdemo_sk    BIGINT,
    cr_returning_addr_sk     BIGINT,
    cr_call_center_sk        BIGINT,
    cr_catalog_page_sk       BIGINT,
    cr_ship_mode_sk          BIGINT,
    cr_warehouse_sk          BIGINT,
    cr_reason_sk             BIGINT,
    cr_order_number          BIGINT NOT NULL,
    cr_return_quantity       BIGINT,
    cr_return_amount         DECIMAL(15,2),
    cr_return_tax            DECIMAL(15,2),
    cr_return_amt_inc_tax    DECIMAL(15,2),
    cr_fee                   DECIMAL(15,2),
    cr_return_ship_cost      DECIMAL(15,2),
    cr_refunded_cash         DECIMAL(15,2),
    cr_reversed_charge       DECIMAL(15,2),
    cr_store_credit          DECIMAL(15,2),
    cr_net_loss              DECIMAL(15,2))
PRIMARY INDEX cr_item_sk, cr_order_number;

CREATE TABLE catalog_sales (
    cs_sold_date_sk          INT,
    cs_sold_time_sk          INT,
    cs_ship_date_sk          INT,
    cs_bill_customer_sk      BIGINT,
    cs_bill_cdemo_sk         BIGINT,
    cs_bill_hdemo_sk         BIGINT,
    cs_bill_addr_sk          BIGINT,
    cs_ship_customer_sk      BIGINT,
    cs_ship_cdemo_sk         BIGINT,
    cs_ship_hdemo_sk         BIGINT,
    cs_ship_addr_sk          BIGINT,
    cs_call_center_sk        BIGINT,
    cs_catalog_page_sk       BIGINT,
    cs_ship_mode_sk          BIGINT,
    cs_warehouse_sk          BIGINT,
    cs_item_sk               BIGINT NOT NULL,
    cs_promo_sk              BIGINT,
    cs_order_number          BIGINT NOT NULL,
    cs_quantity              BIGINT,
    cs_wholesale_cost        DECIMAL(15,2),
    cs_list_price            DECIMAL(15,2),
    cs_sales_price           DECIMAL(15,2),
    cs_ext_discount_amt      DECIMAL(15,2),
    cs_ext_sales_price       DECIMAL(15,2),
    cs_ext_wholesale_cost    DECIMAL(15,2),
    cs_ext_list_price        DECIMAL(15,2),
    cs_ext_tax               DECIMAL(15,2),
    cs_coupon_amt            DECIMAL(15,2),
    cs_ext_ship_cost         DECIMAL(15,2),
    cs_net_paid              DECIMAL(15,2),
    cs_net_paid_inc_tax      DECIMAL(15,2),
    cs_net_paid_inc_ship     DECIMAL(15,2),
    cs_net_paid_inc_ship_tax DECIMAL(15,2),
    cs_net_profit            DECIMAL(15,2))
PRIMARY INDEX cs_item_sk, cs_order_number;

CREATE TABLE customer_address (
    ca_address_sk    BIGINT NOT NULL,
    ca_address_id    TEXT NOT NULL,
    ca_street_number TEXT,
    ca_street_name   TEXT,
    ca_street_type   TEXT,
    ca_suite_number  TEXT,
    ca_city          TEXT,
    ca_county        TEXT,
    ca_state         TEXT,
    ca_zip           TEXT,
    ca_country       TEXT,
    ca_gmt_offset    DECIMAL(15,2),
    ca_location_type TEXT)
PRIMARY INDEX ca_address_sk;

CREATE TABLE customer_demographics (
    cd_demo_sk            BIGINT NOT NULL,
    cd_gender             TEXT,
    cd_marital_status     TEXT,
    cd_education_status   TEXT,
    cd_purchase_estimate  BIGINT,
    cd_credit_rating      TEXT,
    cd_dep_count          BIGINT,
    cd_dep_employed_count BIGINT,
    cd_dep_college_count  BIGINT)
PRIMARY INDEX cd_demo_sk;

CREATE TABLE customer (
    c_customer_sk          BIGINT NOT NULL,
    c_customer_id          TEXT NOT NULL,
    c_current_cdemo_sk     BIGINT,
    c_current_hdemo_sk     BIGINT,
    c_current_addr_sk      BIGINT,
    c_first_shipto_date_sk INT,
    c_first_sales_date_sk  INT,
    c_salutation           TEXT,
    c_first_name           TEXT,
    c_last_name            TEXT,
    c_preferred_cust_flag  TEXT,
    c_birth_day            BIGINT,
    c_birth_month          BIGINT,
    c_birth_year           BIGINT,
    c_birth_country        TEXT,
    c_login                TEXT,
    c_email_address        TEXT,
    c_last_review_date_sk  INT)
PRIMARY INDEX c_customer_sk;

CREATE TABLE date_dim (
    d_date_sk           INT NOT NULL,
    d_date_id           TEXT NOT NULL,
    d_date              DATE NOT NULL,
    d_month_seq         BIGINT,
    d_week_seq          BIGINT,
    d_quarter_seq       BIGINT,
    d_year              BIGINT,
    d_dow               BIGINT,
    d_moy               BIGINT,
    d_dom               BIGINT,
    d_qoy               BIGINT,
    d_fy_year           BIGINT,
    d_fy_quarter_seq    BIGINT,
    d_fy_week_seq       BIGINT,
    d_day_name          TEXT,
    d_quarter_name      TEXT,
    d_holiday           TEXT,
    d_weekend           TEXT,
    d_following_holiday TEXT,
    d_first_dom         BIGINT,
    d_last_dom          BIGINT,
    d_same_day_ly       BIGINT,
    d_same_day_lq       BIGINT,
    d_current_day       TEXT,
    d_current_week      TEXT,
    d_current_month     TEXT,
    d_current_quarter   TEXT,
    d_current_year      TEXT)
PRIMARY INDEX d_date_sk;

CREATE TABLE household_demographics (
    hd_demo_sk        BIGINT NOT NULL,
    hd_income_band_sk BIGINT,
    hd_buy_potential  TEXT,
    hd_dep_count      BIGINT,
    hd_vehicle_count  BIGINT)
PRIMARY INDEX hd_demo_sk;

CREATE TABLE income_band (
    ib_income_band_sk BIGINT NOT NULL,
    ib_lower_bound    BIGINT,
    ib_upper_bound    BIGINT)
PRIMARY INDEX ib_income_band_sk;

CREATE TABLE inventory (
    inv_date_sk          INT NOT NULL,
    inv_item_sk          BIGINT NOT NULL,
    inv_warehouse_sk     BIGINT NOT NULL,
    inv_quantity_on_hand BIGINT)
PRIMARY INDEX inv_date_sk, inv_item_sk, inv_warehouse_sk;

CREATE TABLE item (
    i_item_sk        BIGINT NOT NULL,
    i_item_id        TEXT NOT NULL,
    i_rec_start_date DATE,
    i_rec_end_date   DATE,
    i_item_desc      TEXT,
    i_current_price  DECIMAL(15,2),
    i_wholesale_cost DECIMAL(15,2),
    i_brand_id       BIGINT,
    i_brand          TEXT,
    i_class_id       BIGINT,
    i_class          TEXT,
    i_category_id    BIGINT,
    i_category       TEXT,
    i_manufact_id    BIGINT,
    i_manufact       TEXT,
    i_size           TEXT,
    i_formulation    TEXT,
    i_color          TEXT,
    i_units          TEXT,
    i_container      TEXT,
    i_manager_id     BIGINT,
    i_product_name   TEXT)
PRIMARY INDEX i_item_sk;

CREATE TABLE promotion (
    p_promo_sk        BIGINT NOT NULL,
    p_promo_id        TEXT NOT NULL,
    p_start_date_sk   INT,
    p_end_date_sk     INT,
    p_item_sk         BIGINT,
    p_cost            DECIMAL(15,2),
    p_response_target BIGINT,
    p_promo_name      TEXT,
    p_channel_dmail   TEXT,
    p_channel_email   TEXT,
    p_channel_catalog TEXT,
    p_channel_tv      TEXT,
    p_channel_radio   TEXT,
    p_channel_press   TEXT,
    p_channel_event   TEXT,
    p_channel_demo    TEXT,
    p_channel_details TEXT,
    p_purpose         TEXT,
    p_discount_active TEXT)
PRIMARY INDEX p_promo_sk;

CREATE TABLE reason (
    r_reason_sk   BIGINT NOT NULL,
    r_reason_id   TEXT NOT NULL,
    r_reason_desc TEXT)
PRIMARY INDEX r_reason_sk;

CREATE TABLE ship_mode (
    sm_ship_mode_sk BIGINT NOT NULL,
    sm_ship_mode_id TEXT NOT NULL,
    sm_type         TEXT,
    sm_code         TEXT,
    sm_carrier      TEXT,
    sm_contract     TEXT)
PRIMARY INDEX sm_ship_mode_sk;

CREATE TABLE store_returns (
    sr_returned_date_sk   INT,
    sr_return_time_sk     INT,
    sr_item_sk            BIGINT NOT NULL,
    sr_customer_sk        BIGINT,
    sr_cdemo_sk           BIGINT,
    sr_hdemo_sk           BIGINT,
    sr_addr_sk            BIGINT,
    sr_store_sk           BIGINT,
    sr_reason_sk          BIGINT,
    sr_ticket_number      BIGINT NOT NULL,
    sr_return_quantity    BIGINT,
    sr_return_amt         DECIMAL(15,2),
    sr_return_tax         DECIMAL(15,2),
    sr_return_amt_inc_tax DECIMAL(15,2),
    sr_fee                DECIMAL(15,2),
    sr_return_ship_cost   DECIMAL(15,2),
    sr_refunded_cash      DECIMAL(15,2),
    sr_reversed_charge    DECIMAL(15,2),
    sr_store_credit       DECIMAL(15,2),
    sr_net_loss           DECIMAL(15,2))
PRIMARY INDEX sr_item_sk, sr_ticket_number;

CREATE TABLE store_sales (
    ss_sold_date_sk       INT,
    ss_sold_time_sk       INT,
    ss_item_sk            BIGINT NOT NULL,
    ss_customer_sk        BIGINT,
    ss_cdemo_sk           BIGINT,
    ss_hdemo_sk           BIGINT,
    ss_addr_sk            BIGINT,
    ss_store_sk           BIGINT,
    ss_promo_sk           BIGINT,
    ss_ticket_number      BIGINT NOT NULL,
    ss_quantity           BIGINT,
    ss_wholesale_cost     DECIMAL(15,2),
    ss_list_price         DECIMAL(15,2),
    ss_sales_price        DECIMAL(15,2),
    ss_ext_discount_amt   DECIMAL(15,2),
    ss_ext_sales_price    DECIMAL(15,2),
    ss_ext_wholesale_cost DECIMAL(15,2),
    ss_ext_list_price     DECIMAL(15,2),
    ss_ext_tax            DECIMAL(15,2),
    ss_coupon_amt         DECIMAL(15,2),
    ss_net_paid           DECIMAL(15,2),
    ss_net_paid_inc_tax   DECIMAL(15,2),
    ss_net_profit         DECIMAL(15,2))
PRIMARY INDEX ss_item_sk, ss_ticket_number;

CREATE TABLE store (
    s_store_sk         BIGINT NOT NULL,
    s_store_id         TEXT NOT NULL,
    s_rec_start_date   DATE,
    s_rec_end_date     DATE,
    s_closed_date_sk   INT,
    s_store_name       TEXT,
    s_number_employees BIGINT,
    s_floor_space      BIGINT,
    s_hours            TEXT,
    s_manager          TEXT,
    s_market_id        BIGINT,
    s_geography_class  TEXT,
    s_market_desc      TEXT,
    s_market_manager   TEXT,
    s_division_id      BIGINT,
    s_division_name    TEXT,
    s_company_id       BIGINT,
    s_company_name     TEXT,
    s_street_number    TEXT,
    s_street_name      TEXT,
    s_street_type      TEXT,
    s_suite_number     TEXT,
    s_city             TEXT,
    s_county           TEXT,
    s_state            TEXT,
    s_zip              TEXT,
    s_country          TEXT,
    s_gmt_offset       DECIMAL(15,2),
    s_tax_percentage   DECIMAL(15,2))
PRIMARY INDEX s_store_sk;

CREATE TABLE time_dim (
    t_time_sk   INT NOT NULL,
    t_time_id   TEXT NOT NULL,
    t_time      BIGINT NOT NULL,
    t_hour      BIGINT,
    t_minute    BIGINT,
    t_second    BIGINT,
    t_am_pm     TEXT,
    t_shift     TEXT,
    t_sub_shift TEXT,
    t_meal_time TEXT)
PRIMARY INDEX t_time_sk;

CREATE TABLE warehouse (
    w_warehouse_sk    BIGINT NOT NULL,
    w_warehouse_id    TEXT NOT NULL,
    w_warehouse_name  TEXT,
    w_warehouse_sq_ft BIGINT,
    w_street_number   TEXT,
    w_street_name     TEXT,
    w_street_type     TEXT,
    w_suite_number    TEXT,
    w_city            TEXT,
    w_county          TEXT,
    w_state           TEXT,
    w_zip             TEXT,
    w_country         TEXT,
    w_gmt_offset      DECIMAL(15,2))
PRIMARY INDEX w_warehouse_sk;

CREATE TABLE web_page (
    wp_web_page_sk      BIGINT NOT NULL,
    wp_web_page_id      TEXT NOT NULL,
    wp_rec_start_date   DATE,
    wp_rec_end_date     DATE,
    wp_creation_date_sk INT,
    wp_access_date_sk   INT,
    wp_autogen_flag     TEXT,
    wp_customer_sk      BIGINT,
    wp_url              TEXT,
    wp_type             TEXT,
    wp_char_count       BIGINT,
    wp_link_count       BIGINT,
    wp_image_count      BIGINT,
    wp_max_ad_count     BIGINT)
PRIMARY INDEX wp_web_page_sk;

CREATE TABLE web_returns (
    wr_returned_date_sk      INT,
    wr_returned_time_sk      INT,
    wr_item_sk               BIGINT NOT NULL,
    wr_refunded_customer_sk  BIGINT,
    wr_refunded_cdemo_sk     BIGINT,
    wr_refunded_hdemo_sk     BIGINT,
    wr_refunded_addr_sk      BIGINT,
    wr_returning_customer_sk BIGINT,
    wr_returning_cdemo_sk    BIGINT,
    wr_returning_hdemo_sk    BIGINT,
    wr_returning_addr_sk     BIGINT,
    wr_web_page_sk           BIGINT,
    wr_reason_sk             BIGINT,
    wr_order_number          BIGINT NOT NULL,
    wr_return_quantity       BIGINT,
    wr_return_amt            DECIMAL(15,2),
    wr_return_tax            DECIMAL(15,2),
    wr_return_amt_inc_tax    DECIMAL(15,2),
    wr_fee                   DECIMAL(15,2),
    wr_return_ship_cost      DECIMAL(15,2),
    wr_refunded_cash         DECIMAL(15,2),
    wr_reversed_charge       DECIMAL(15,2),
    wr_account_credit        DECIMAL(15,2),
    wr_net_loss              DECIMAL(15,2))
PRIMARY INDEX wr_item_sk, wr_order_number;

CREATE TABLE web_sales (
    ws_sold_date_sk          INT,
    ws_sold_time_sk          INT,
    ws_ship_date_sk          INT,
    ws_item_sk               BIGINT NOT NULL,
    ws_bill_customer_sk      BIGINT,
    ws_bill_cdemo_sk         BIGINT,
    ws_bill_hdemo_sk         BIGINT,
    ws_bill_addr_sk          BIGINT,
    ws_ship_customer_sk      BIGINT,
    ws_ship_cdemo_sk         BIGINT,
    ws_ship_hdemo_sk         BIGINT,
    ws_ship_addr_sk          BIGINT,
    ws_web_page_sk           BIGINT,
    ws_web_site_sk           BIGINT,
    ws_ship_mode_sk          BIGINT,
    ws_warehouse_sk          BIGINT,
    ws_promo_sk              BIGINT,
    ws_order_number          BIGINT NOT NULL,
    ws_quantity              BIGINT,
    ws_wholesale_cost        DECIMAL(15,2),
    ws_list_price            DECIMAL(15,2),
    ws_sales_price           DECIMAL(15,2),
    ws_ext_discount_amt      DECIMAL(15,2),
    ws_ext_sales_price       DECIMAL(15,2),
    ws_ext_wholesale_cost    DECIMAL(15,2),
    ws_ext_list_price        DECIMAL(15,2),
    ws_ext_tax               DECIMAL(15,2),
    ws_coupon_amt            DECIMAL(15,2),
    ws_ext_ship_cost         DECIMAL(15,2),
    ws_net_paid              DECIMAL(15,2),
    ws_net_paid_inc_tax      DECIMAL(15,2),
    ws_net_paid_inc_ship     DECIMAL(15,2),
    ws_net_paid_inc_ship_tax DECIMAL(15,2),
    ws_net_profit            DECIMAL(15,2))
PRIMARY INDEX ws_item_sk, ws_order_number;

CREATE TABLE web_site (
    web_site_sk        BIGINT NOT NULL,
    web_site_id        TEXT NOT NULL,
    web_rec_start_date DATE,
    web_rec_end_date   DATE,
    web_name           TEXT,
    web_open_date_sk   INT,
    web_close_date_sk  INT,
    web_class          TEXT,
    web_manager        TEXT,
    web_mkt_id         BIGINT,
    web_mkt_class      TEXT,
    web_mkt_desc       TEXT,
    web_market_manager TEXT,
    web_company_id     BIGINT,
    web_company_name   TEXT,
    web_street_number  TEXT,
    web_street_name    TEXT,
    web_street_type    TEXT,
    web_suite_number   TEXT,
    web_city           TEXT,
    web_county         TEXT,
    web_state          TEXT,
    web_zip            TEXT,
    web_country        TEXT,
    web_gmt_offset     DECIMAL(15,2),
    web_tax_percentage DECIMAL(15,2))
PRIMARY INDEX web_site_sk;

