-- TPCDS schema for Umbra. Column types and widths follow the benchmark spec -- char(N),
-- varchar(N), decimal(P,S) -- rather than a widened lowest-common-denominator, so all
-- systems declare the same thing in their own dialect. COLUMN ORDER IS SIGNIFICANT: the
-- load does SELECT * from the Parquet, so reordering a column corrupts that table.

CREATE SCHEMA IF NOT EXISTS tpcds;
-- Selected once for the whole script: the runner feeds this file to a single
-- psql session, so every table below can be named unqualified.
SET search_path TO tpcds;

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
    cc_call_center_sk bigint NOT NULL,
    cc_call_center_id char(16) NOT NULL,
    cc_rec_start_date date,
    cc_rec_end_date   date,
    cc_closed_date_sk integer,
    cc_open_date_sk   integer,
    cc_name           varchar(50),
    cc_class          varchar(50),
    cc_employees      bigint,
    cc_sq_ft          bigint,
    cc_hours          char(20),
    cc_manager        varchar(40),
    cc_mkt_id         bigint,
    cc_mkt_class      char(50),
    cc_mkt_desc       varchar(100),
    cc_market_manager varchar(40),
    cc_division       bigint,
    cc_division_name  varchar(50),
    cc_company        bigint,
    cc_company_name   char(50),
    cc_street_number  char(10),
    cc_street_name    varchar(60),
    cc_street_type    char(15),
    cc_suite_number   char(10),
    cc_city           varchar(60),
    cc_county         varchar(30),
    cc_state          char(2),
    cc_zip            char(10),
    cc_country        varchar(20),
    cc_gmt_offset     numeric(5,2),
    cc_tax_percentage numeric(5,2),
    PRIMARY KEY (cc_call_center_sk)
);

CREATE TABLE catalog_page (
    cp_catalog_page_sk     bigint NOT NULL,
    cp_catalog_page_id     char(16) NOT NULL,
    cp_start_date_sk       integer,
    cp_end_date_sk         integer,
    cp_department          varchar(50),
    cp_catalog_number      bigint,
    cp_catalog_page_number bigint,
    cp_description         varchar(100),
    cp_type                varchar(100),
    PRIMARY KEY (cp_catalog_page_sk)
);

CREATE TABLE catalog_returns (
    cr_returned_date_sk      integer,
    cr_returned_time_sk      integer,
    cr_item_sk               bigint NOT NULL,
    cr_refunded_customer_sk  bigint,
    cr_refunded_cdemo_sk     bigint,
    cr_refunded_hdemo_sk     bigint,
    cr_refunded_addr_sk      bigint,
    cr_returning_customer_sk bigint,
    cr_returning_cdemo_sk    bigint,
    cr_returning_hdemo_sk    bigint,
    cr_returning_addr_sk     bigint,
    cr_call_center_sk        bigint,
    cr_catalog_page_sk       bigint,
    cr_ship_mode_sk          bigint,
    cr_warehouse_sk          bigint,
    cr_reason_sk             bigint,
    cr_order_number          bigint NOT NULL,
    cr_return_quantity       bigint,
    cr_return_amount         numeric(7,2),
    cr_return_tax            numeric(7,2),
    cr_return_amt_inc_tax    numeric(7,2),
    cr_fee                   numeric(7,2),
    cr_return_ship_cost      numeric(7,2),
    cr_refunded_cash         numeric(7,2),
    cr_reversed_charge       numeric(7,2),
    cr_store_credit          numeric(7,2),
    cr_net_loss              numeric(7,2),
    PRIMARY KEY (cr_item_sk, cr_order_number)
);

CREATE TABLE catalog_sales (
    cs_sold_date_sk          integer,
    cs_sold_time_sk          integer,
    cs_ship_date_sk          integer,
    cs_bill_customer_sk      bigint,
    cs_bill_cdemo_sk         bigint,
    cs_bill_hdemo_sk         bigint,
    cs_bill_addr_sk          bigint,
    cs_ship_customer_sk      bigint,
    cs_ship_cdemo_sk         bigint,
    cs_ship_hdemo_sk         bigint,
    cs_ship_addr_sk          bigint,
    cs_call_center_sk        bigint,
    cs_catalog_page_sk       bigint,
    cs_ship_mode_sk          bigint,
    cs_warehouse_sk          bigint,
    cs_item_sk               bigint NOT NULL,
    cs_promo_sk              bigint,
    cs_order_number          bigint NOT NULL,
    cs_quantity              bigint,
    cs_wholesale_cost        numeric(7,2),
    cs_list_price            numeric(7,2),
    cs_sales_price           numeric(7,2),
    cs_ext_discount_amt      numeric(7,2),
    cs_ext_sales_price       numeric(7,2),
    cs_ext_wholesale_cost    numeric(7,2),
    cs_ext_list_price        numeric(7,2),
    cs_ext_tax               numeric(7,2),
    cs_coupon_amt            numeric(7,2),
    cs_ext_ship_cost         numeric(7,2),
    cs_net_paid              numeric(7,2),
    cs_net_paid_inc_tax      numeric(7,2),
    cs_net_paid_inc_ship     numeric(7,2),
    cs_net_paid_inc_ship_tax numeric(7,2),
    cs_net_profit            numeric(7,2),
    PRIMARY KEY (cs_item_sk, cs_order_number)
);

CREATE TABLE customer_address (
    ca_address_sk    bigint NOT NULL,
    ca_address_id    char(16) NOT NULL,
    ca_street_number char(10),
    ca_street_name   varchar(60),
    ca_street_type   char(15),
    ca_suite_number  char(10),
    ca_city          varchar(60),
    ca_county        varchar(30),
    ca_state         char(2),
    ca_zip           char(10),
    ca_country       varchar(20),
    ca_gmt_offset    numeric(5,2),
    ca_location_type char(20),
    PRIMARY KEY (ca_address_sk)
);

CREATE TABLE customer_demographics (
    cd_demo_sk            bigint NOT NULL,
    cd_gender             char(1),
    cd_marital_status     char(1),
    cd_education_status   char(20),
    cd_purchase_estimate  bigint,
    cd_credit_rating      char(10),
    cd_dep_count          bigint,
    cd_dep_employed_count bigint,
    cd_dep_college_count  bigint,
    PRIMARY KEY (cd_demo_sk)
);

CREATE TABLE customer (
    c_customer_sk          bigint NOT NULL,
    c_customer_id          char(16) NOT NULL,
    c_current_cdemo_sk     bigint,
    c_current_hdemo_sk     bigint,
    c_current_addr_sk      bigint,
    c_first_shipto_date_sk integer,
    c_first_sales_date_sk  integer,
    c_salutation           char(10),
    c_first_name           char(20),
    c_last_name            char(30),
    c_preferred_cust_flag  char(1),
    c_birth_day            bigint,
    c_birth_month          bigint,
    c_birth_year           bigint,
    c_birth_country        varchar(20),
    c_login                char(13),
    c_email_address        char(50),
    c_last_review_date_sk  integer,
    PRIMARY KEY (c_customer_sk)
);

CREATE TABLE date_dim (
    d_date_sk           integer NOT NULL,
    d_date_id           char(16) NOT NULL,
    d_date              date NOT NULL,
    d_month_seq         bigint,
    d_week_seq          bigint,
    d_quarter_seq       bigint,
    d_year              bigint,
    d_dow               bigint,
    d_moy               bigint,
    d_dom               bigint,
    d_qoy               bigint,
    d_fy_year           bigint,
    d_fy_quarter_seq    bigint,
    d_fy_week_seq       bigint,
    d_day_name          char(9),
    d_quarter_name      char(6),
    d_holiday           char(1),
    d_weekend           char(1),
    d_following_holiday char(1),
    d_first_dom         bigint,
    d_last_dom          bigint,
    d_same_day_ly       bigint,
    d_same_day_lq       bigint,
    d_current_day       char(1),
    d_current_week      char(1),
    d_current_month     char(1),
    d_current_quarter   char(1),
    d_current_year      char(1),
    PRIMARY KEY (d_date_sk)
);

CREATE TABLE household_demographics (
    hd_demo_sk        bigint NOT NULL,
    hd_income_band_sk bigint,
    hd_buy_potential  char(15),
    hd_dep_count      bigint,
    hd_vehicle_count  bigint,
    PRIMARY KEY (hd_demo_sk)
);

CREATE TABLE income_band (
    ib_income_band_sk bigint NOT NULL,
    ib_lower_bound    bigint,
    ib_upper_bound    bigint,
    PRIMARY KEY (ib_income_band_sk)
);

CREATE TABLE inventory (
    inv_date_sk          integer NOT NULL,
    inv_item_sk          bigint NOT NULL,
    inv_warehouse_sk     bigint NOT NULL,
    inv_quantity_on_hand bigint,
    PRIMARY KEY (inv_date_sk, inv_item_sk, inv_warehouse_sk)
);

CREATE TABLE item (
    i_item_sk        bigint NOT NULL,
    i_item_id        char(16) NOT NULL,
    i_rec_start_date date,
    i_rec_end_date   date,
    i_item_desc      varchar(200),
    i_current_price  numeric(7,2),
    i_wholesale_cost numeric(7,2),
    i_brand_id       bigint,
    i_brand          char(50),
    i_class_id       bigint,
    i_class          char(50),
    i_category_id    bigint,
    i_category       char(50),
    i_manufact_id    bigint,
    i_manufact       char(50),
    i_size           char(20),
    i_formulation    char(20),
    i_color          char(20),
    i_units          char(10),
    i_container      char(10),
    i_manager_id     bigint,
    i_product_name   char(50),
    PRIMARY KEY (i_item_sk)
);

CREATE TABLE promotion (
    p_promo_sk        bigint NOT NULL,
    p_promo_id        char(16) NOT NULL,
    p_start_date_sk   integer,
    p_end_date_sk     integer,
    p_item_sk         bigint,
    p_cost            numeric(15,2),
    p_response_target bigint,
    p_promo_name      char(50),
    p_channel_dmail   char(1),
    p_channel_email   char(1),
    p_channel_catalog char(1),
    p_channel_tv      char(1),
    p_channel_radio   char(1),
    p_channel_press   char(1),
    p_channel_event   char(1),
    p_channel_demo    char(1),
    p_channel_details varchar(100),
    p_purpose         char(15),
    p_discount_active char(1),
    PRIMARY KEY (p_promo_sk)
);

CREATE TABLE reason (
    r_reason_sk   bigint NOT NULL,
    r_reason_id   char(16) NOT NULL,
    r_reason_desc char(100),
    PRIMARY KEY (r_reason_sk)
);

CREATE TABLE ship_mode (
    sm_ship_mode_sk bigint NOT NULL,
    sm_ship_mode_id char(16) NOT NULL,
    sm_type         char(30),
    sm_code         char(10),
    sm_carrier      char(20),
    sm_contract     char(20),
    PRIMARY KEY (sm_ship_mode_sk)
);

CREATE TABLE store_returns (
    sr_returned_date_sk   integer,
    sr_return_time_sk     integer,
    sr_item_sk            bigint NOT NULL,
    sr_customer_sk        bigint,
    sr_cdemo_sk           bigint,
    sr_hdemo_sk           bigint,
    sr_addr_sk            bigint,
    sr_store_sk           bigint,
    sr_reason_sk          bigint,
    sr_ticket_number      bigint NOT NULL,
    sr_return_quantity    bigint,
    sr_return_amt         numeric(7,2),
    sr_return_tax         numeric(7,2),
    sr_return_amt_inc_tax numeric(7,2),
    sr_fee                numeric(7,2),
    sr_return_ship_cost   numeric(7,2),
    sr_refunded_cash      numeric(7,2),
    sr_reversed_charge    numeric(7,2),
    sr_store_credit       numeric(7,2),
    sr_net_loss           numeric(7,2),
    PRIMARY KEY (sr_item_sk, sr_ticket_number)
);

CREATE TABLE store_sales (
    ss_sold_date_sk       integer,
    ss_sold_time_sk       integer,
    ss_item_sk            bigint NOT NULL,
    ss_customer_sk        bigint,
    ss_cdemo_sk           bigint,
    ss_hdemo_sk           bigint,
    ss_addr_sk            bigint,
    ss_store_sk           bigint,
    ss_promo_sk           bigint,
    ss_ticket_number      bigint NOT NULL,
    ss_quantity           bigint,
    ss_wholesale_cost     numeric(7,2),
    ss_list_price         numeric(7,2),
    ss_sales_price        numeric(7,2),
    ss_ext_discount_amt   numeric(7,2),
    ss_ext_sales_price    numeric(7,2),
    ss_ext_wholesale_cost numeric(7,2),
    ss_ext_list_price     numeric(7,2),
    ss_ext_tax            numeric(7,2),
    ss_coupon_amt         numeric(7,2),
    ss_net_paid           numeric(7,2),
    ss_net_paid_inc_tax   numeric(7,2),
    ss_net_profit         numeric(7,2),
    PRIMARY KEY (ss_item_sk, ss_ticket_number)
);

CREATE TABLE store (
    s_store_sk         bigint NOT NULL,
    s_store_id         char(16) NOT NULL,
    s_rec_start_date   date,
    s_rec_end_date     date,
    s_closed_date_sk   integer,
    s_store_name       varchar(50),
    s_number_employees bigint,
    s_floor_space      bigint,
    s_hours            char(20),
    s_manager          varchar(40),
    s_market_id        bigint,
    s_geography_class  varchar(100),
    s_market_desc      varchar(100),
    s_market_manager   varchar(40),
    s_division_id      bigint,
    s_division_name    varchar(50),
    s_company_id       bigint,
    s_company_name     varchar(50),
    s_street_number    varchar(10),
    s_street_name      varchar(60),
    s_street_type      char(15),
    s_suite_number     char(10),
    s_city             varchar(60),
    s_county           varchar(30),
    s_state            char(2),
    s_zip              char(10),
    s_country          varchar(20),
    s_gmt_offset       numeric(5,2),
    s_tax_percentage   numeric(5,2),
    PRIMARY KEY (s_store_sk)
);

CREATE TABLE time_dim (
    t_time_sk   integer NOT NULL,
    t_time_id   char(16) NOT NULL,
    t_time      bigint NOT NULL,
    t_hour      bigint,
    t_minute    bigint,
    t_second    bigint,
    t_am_pm     char(2),
    t_shift     char(20),
    t_sub_shift char(20),
    t_meal_time char(20),
    PRIMARY KEY (t_time_sk)
);

CREATE TABLE warehouse (
    w_warehouse_sk    bigint NOT NULL,
    w_warehouse_id    char(16) NOT NULL,
    w_warehouse_name  varchar(20),
    w_warehouse_sq_ft bigint,
    w_street_number   char(10),
    w_street_name     varchar(60),
    w_street_type     char(15),
    w_suite_number    char(10),
    w_city            varchar(60),
    w_county          varchar(30),
    w_state           char(2),
    w_zip             char(10),
    w_country         varchar(20),
    w_gmt_offset      numeric(5,2),
    PRIMARY KEY (w_warehouse_sk)
);

CREATE TABLE web_page (
    wp_web_page_sk      bigint NOT NULL,
    wp_web_page_id      char(16) NOT NULL,
    wp_rec_start_date   date,
    wp_rec_end_date     date,
    wp_creation_date_sk integer,
    wp_access_date_sk   integer,
    wp_autogen_flag     char(1),
    wp_customer_sk      bigint,
    wp_url              varchar(100),
    wp_type             char(50),
    wp_char_count       bigint,
    wp_link_count       bigint,
    wp_image_count      bigint,
    wp_max_ad_count     bigint,
    PRIMARY KEY (wp_web_page_sk)
);

CREATE TABLE web_returns (
    wr_returned_date_sk      integer,
    wr_returned_time_sk      integer,
    wr_item_sk               bigint NOT NULL,
    wr_refunded_customer_sk  bigint,
    wr_refunded_cdemo_sk     bigint,
    wr_refunded_hdemo_sk     bigint,
    wr_refunded_addr_sk      bigint,
    wr_returning_customer_sk bigint,
    wr_returning_cdemo_sk    bigint,
    wr_returning_hdemo_sk    bigint,
    wr_returning_addr_sk     bigint,
    wr_web_page_sk           bigint,
    wr_reason_sk             bigint,
    wr_order_number          bigint NOT NULL,
    wr_return_quantity       bigint,
    wr_return_amt            numeric(7,2),
    wr_return_tax            numeric(7,2),
    wr_return_amt_inc_tax    numeric(7,2),
    wr_fee                   numeric(7,2),
    wr_return_ship_cost      numeric(7,2),
    wr_refunded_cash         numeric(7,2),
    wr_reversed_charge       numeric(7,2),
    wr_account_credit        numeric(7,2),
    wr_net_loss              numeric(7,2),
    PRIMARY KEY (wr_item_sk, wr_order_number)
);

CREATE TABLE web_sales (
    ws_sold_date_sk          integer,
    ws_sold_time_sk          integer,
    ws_ship_date_sk          integer,
    ws_item_sk               bigint NOT NULL,
    ws_bill_customer_sk      bigint,
    ws_bill_cdemo_sk         bigint,
    ws_bill_hdemo_sk         bigint,
    ws_bill_addr_sk          bigint,
    ws_ship_customer_sk      bigint,
    ws_ship_cdemo_sk         bigint,
    ws_ship_hdemo_sk         bigint,
    ws_ship_addr_sk          bigint,
    ws_web_page_sk           bigint,
    ws_web_site_sk           bigint,
    ws_ship_mode_sk          bigint,
    ws_warehouse_sk          bigint,
    ws_promo_sk              bigint,
    ws_order_number          bigint NOT NULL,
    ws_quantity              bigint,
    ws_wholesale_cost        numeric(7,2),
    ws_list_price            numeric(7,2),
    ws_sales_price           numeric(7,2),
    ws_ext_discount_amt      numeric(7,2),
    ws_ext_sales_price       numeric(7,2),
    ws_ext_wholesale_cost    numeric(7,2),
    ws_ext_list_price        numeric(7,2),
    ws_ext_tax               numeric(7,2),
    ws_coupon_amt            numeric(7,2),
    ws_ext_ship_cost         numeric(7,2),
    ws_net_paid              numeric(7,2),
    ws_net_paid_inc_tax      numeric(7,2),
    ws_net_paid_inc_ship     numeric(7,2),
    ws_net_paid_inc_ship_tax numeric(7,2),
    ws_net_profit            numeric(7,2),
    PRIMARY KEY (ws_item_sk, ws_order_number)
);

CREATE TABLE web_site (
    web_site_sk        bigint NOT NULL,
    web_site_id        char(16) NOT NULL,
    web_rec_start_date date,
    web_rec_end_date   date,
    web_name           varchar(50),
    web_open_date_sk   integer,
    web_close_date_sk  integer,
    web_class          varchar(50),
    web_manager        varchar(40),
    web_mkt_id         bigint,
    web_mkt_class      varchar(50),
    web_mkt_desc       varchar(100),
    web_market_manager varchar(40),
    web_company_id     bigint,
    web_company_name   char(50),
    web_street_number  char(10),
    web_street_name    varchar(60),
    web_street_type    char(15),
    web_suite_number   char(10),
    web_city           varchar(60),
    web_county         varchar(30),
    web_state          char(2),
    web_zip            char(10),
    web_country        varchar(20),
    web_gmt_offset     numeric(5,2),
    web_tax_percentage numeric(5,2),
    PRIMARY KEY (web_site_sk)
);

