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
    cc_call_center_sk         BIGINT NOT NULL,
    cc_call_center_id         CHAR(16) NOT NULL,
    cc_rec_start_date         DATE,
    cc_rec_end_date           DATE,
    cc_closed_date_sk         INT,
    cc_open_date_sk           INT,
    cc_name                   VARCHAR(50),
    cc_class                  VARCHAR(50),
    cc_employees              BIGINT,
    cc_sq_ft                  BIGINT,
    cc_hours                  CHAR(20),
    cc_manager                VARCHAR(40),
    cc_mkt_id                 BIGINT,
    cc_mkt_class              CHAR(50),
    cc_mkt_desc               VARCHAR(100),
    cc_market_manager         VARCHAR(40),
    cc_division               BIGINT,
    cc_division_name          VARCHAR(50),
    cc_company                BIGINT,
    cc_company_name           CHAR(50),
    cc_street_number          CHAR(10),
    cc_street_name            VARCHAR(60),
    cc_street_type            CHAR(15),
    cc_suite_number           CHAR(10),
    cc_city                   VARCHAR(60),
    cc_county                 VARCHAR(30),
    cc_state                  CHAR(2),
    cc_zip                    CHAR(10),
    cc_country                VARCHAR(20),
    cc_gmt_offset             DECIMAL(5,2),
    cc_tax_percentage         DECIMAL(5,2))
ORDER BY (cc_call_center_sk);

CREATE TABLE catalog_page (
    cp_catalog_page_sk        BIGINT NOT NULL,
    cp_catalog_page_id        CHAR(16) NOT NULL,
    cp_start_date_sk          INT,
    cp_end_date_sk            INT,
    cp_department             VARCHAR(50),
    cp_catalog_number         BIGINT,
    cp_catalog_page_number    BIGINT,
    cp_description            VARCHAR(100),
    cp_type                   VARCHAR(100))
ORDER BY (cp_catalog_page_sk);

CREATE TABLE catalog_returns (
    cr_returned_date_sk       INT,
    cr_returned_time_sk       INT,
    cr_item_sk                BIGINT NOT NULL,
    cr_refunded_customer_sk   BIGINT,
    cr_refunded_cdemo_sk      BIGINT,
    cr_refunded_hdemo_sk      BIGINT,
    cr_refunded_addr_sk       BIGINT,
    cr_returning_customer_sk  BIGINT,
    cr_returning_cdemo_sk     BIGINT,
    cr_returning_hdemo_sk     BIGINT,
    cr_returning_addr_sk      BIGINT,
    cr_call_center_sk         BIGINT,
    cr_catalog_page_sk        BIGINT,
    cr_ship_mode_sk           BIGINT,
    cr_warehouse_sk           BIGINT,
    cr_reason_sk              BIGINT,
    cr_order_number           BIGINT NOT NULL,
    cr_return_quantity        BIGINT,
    cr_return_amount          DECIMAL(7,2),
    cr_return_tax             DECIMAL(7,2),
    cr_return_amt_inc_tax     DECIMAL(7,2),
    cr_fee                    DECIMAL(7,2),
    cr_return_ship_cost       DECIMAL(7,2),
    cr_refunded_cash          DECIMAL(7,2),
    cr_reversed_charge        DECIMAL(7,2),
    cr_store_credit           DECIMAL(7,2),
    cr_net_loss               DECIMAL(7,2))
ORDER BY (cr_item_sk, cr_order_number);

CREATE TABLE catalog_sales (
    cs_sold_date_sk           INT,
    cs_sold_time_sk           INT,
    cs_ship_date_sk           INT,
    cs_bill_customer_sk       BIGINT,
    cs_bill_cdemo_sk          BIGINT,
    cs_bill_hdemo_sk          BIGINT,
    cs_bill_addr_sk           BIGINT,
    cs_ship_customer_sk       BIGINT,
    cs_ship_cdemo_sk          BIGINT,
    cs_ship_hdemo_sk          BIGINT,
    cs_ship_addr_sk           BIGINT,
    cs_call_center_sk         BIGINT,
    cs_catalog_page_sk        BIGINT,
    cs_ship_mode_sk           BIGINT,
    cs_warehouse_sk           BIGINT,
    cs_item_sk                BIGINT NOT NULL,
    cs_promo_sk               BIGINT,
    cs_order_number           BIGINT NOT NULL,
    cs_quantity               BIGINT,
    cs_wholesale_cost         DECIMAL(7,2),
    cs_list_price             DECIMAL(7,2),
    cs_sales_price            DECIMAL(7,2),
    cs_ext_discount_amt       DECIMAL(7,2),
    cs_ext_sales_price        DECIMAL(7,2),
    cs_ext_wholesale_cost     DECIMAL(7,2),
    cs_ext_list_price         DECIMAL(7,2),
    cs_ext_tax                DECIMAL(7,2),
    cs_coupon_amt             DECIMAL(7,2),
    cs_ext_ship_cost          DECIMAL(7,2),
    cs_net_paid               DECIMAL(7,2),
    cs_net_paid_inc_tax       DECIMAL(7,2),
    cs_net_paid_inc_ship      DECIMAL(7,2),
    cs_net_paid_inc_ship_tax  DECIMAL(7,2),
    cs_net_profit             DECIMAL(7,2))
ORDER BY (cs_item_sk, cs_order_number);

CREATE TABLE customer_address (
    ca_address_sk             BIGINT NOT NULL,
    ca_address_id             CHAR(16) NOT NULL,
    ca_street_number          CHAR(10),
    ca_street_name            VARCHAR(60),
    ca_street_type            CHAR(15),
    ca_suite_number           CHAR(10),
    ca_city                   VARCHAR(60),
    ca_county                 VARCHAR(30),
    ca_state                  CHAR(2),
    ca_zip                    CHAR(10),
    ca_country                VARCHAR(20),
    ca_gmt_offset             DECIMAL(5,2),
    ca_location_type          CHAR(20))
ORDER BY (ca_address_sk);

CREATE TABLE customer_demographics (
    cd_demo_sk                BIGINT NOT NULL,
    cd_gender                 CHAR(1),
    cd_marital_status         CHAR(1),
    cd_education_status       CHAR(20),
    cd_purchase_estimate      BIGINT,
    cd_credit_rating          CHAR(10),
    cd_dep_count              BIGINT,
    cd_dep_employed_count     BIGINT,
    cd_dep_college_count      BIGINT)
ORDER BY (cd_demo_sk);

CREATE TABLE customer (
    c_customer_sk             BIGINT NOT NULL,
    c_customer_id             CHAR(16) NOT NULL,
    c_current_cdemo_sk        BIGINT,
    c_current_hdemo_sk        BIGINT,
    c_current_addr_sk         BIGINT,
    c_first_shipto_date_sk    INT,
    c_first_sales_date_sk     INT,
    c_salutation              CHAR(10),
    c_first_name              CHAR(20),
    c_last_name               CHAR(30),
    c_preferred_cust_flag     CHAR(1),
    c_birth_day               BIGINT,
    c_birth_month             BIGINT,
    c_birth_year              BIGINT,
    c_birth_country           VARCHAR(20),
    c_login                   CHAR(13),
    c_email_address           CHAR(50),
    c_last_review_date_sk     INT)
ORDER BY (c_customer_sk);

CREATE TABLE date_dim (
    d_date_sk                 INT NOT NULL,
    d_date_id                 CHAR(16) NOT NULL,
    d_date                    DATE NOT NULL,
    d_month_seq               BIGINT,
    d_week_seq                BIGINT,
    d_quarter_seq             BIGINT,
    d_year                    BIGINT,
    d_dow                     BIGINT,
    d_moy                     BIGINT,
    d_dom                     BIGINT,
    d_qoy                     BIGINT,
    d_fy_year                 BIGINT,
    d_fy_quarter_seq          BIGINT,
    d_fy_week_seq             BIGINT,
    d_day_name                CHAR(9),
    d_quarter_name            CHAR(6),
    d_holiday                 CHAR(1),
    d_weekend                 CHAR(1),
    d_following_holiday       CHAR(1),
    d_first_dom               BIGINT,
    d_last_dom                BIGINT,
    d_same_day_ly             BIGINT,
    d_same_day_lq             BIGINT,
    d_current_day             CHAR(1),
    d_current_week            CHAR(1),
    d_current_month           CHAR(1),
    d_current_quarter         CHAR(1),
    d_current_year            CHAR(1))
ORDER BY (d_date_sk);

CREATE TABLE household_demographics (
    hd_demo_sk                BIGINT NOT NULL,
    hd_income_band_sk         BIGINT,
    hd_buy_potential          CHAR(15),
    hd_dep_count              BIGINT,
    hd_vehicle_count          BIGINT)
ORDER BY (hd_demo_sk);

CREATE TABLE income_band (
    ib_income_band_sk         BIGINT NOT NULL,
    ib_lower_bound            BIGINT,
    ib_upper_bound            BIGINT)
ORDER BY (ib_income_band_sk);

CREATE TABLE inventory (
    inv_date_sk               INT NOT NULL,
    inv_item_sk               BIGINT NOT NULL,
    inv_warehouse_sk          BIGINT NOT NULL,
    inv_quantity_on_hand      BIGINT)
ORDER BY (inv_date_sk, inv_item_sk, inv_warehouse_sk);

CREATE TABLE item (
    i_item_sk                 BIGINT NOT NULL,
    i_item_id                 CHAR(16) NOT NULL,
    i_rec_start_date          DATE,
    i_rec_end_date            DATE,
    i_item_desc               VARCHAR(200),
    i_current_price           DECIMAL(7,2),
    i_wholesale_cost          DECIMAL(7,2),
    i_brand_id                BIGINT,
    i_brand                   CHAR(50),
    i_class_id                BIGINT,
    i_class                   CHAR(50),
    i_category_id             BIGINT,
    i_category                CHAR(50),
    i_manufact_id             BIGINT,
    i_manufact                CHAR(50),
    i_size                    CHAR(20),
    i_formulation             CHAR(20),
    i_color                   CHAR(20),
    i_units                   CHAR(10),
    i_container               CHAR(10),
    i_manager_id              BIGINT,
    i_product_name            CHAR(50))
ORDER BY (i_item_sk);

CREATE TABLE promotion (
    p_promo_sk                BIGINT NOT NULL,
    p_promo_id                CHAR(16) NOT NULL,
    p_start_date_sk           INT,
    p_end_date_sk             INT,
    p_item_sk                 BIGINT,
    p_cost                    DECIMAL(15,2),
    p_response_target         BIGINT,
    p_promo_name              CHAR(50),
    p_channel_dmail           CHAR(1),
    p_channel_email           CHAR(1),
    p_channel_catalog         CHAR(1),
    p_channel_tv              CHAR(1),
    p_channel_radio           CHAR(1),
    p_channel_press           CHAR(1),
    p_channel_event           CHAR(1),
    p_channel_demo            CHAR(1),
    p_channel_details         VARCHAR(100),
    p_purpose                 CHAR(15),
    p_discount_active         CHAR(1))
ORDER BY (p_promo_sk);

CREATE TABLE reason (
    r_reason_sk               BIGINT NOT NULL,
    r_reason_id               CHAR(16) NOT NULL,
    r_reason_desc             CHAR(100))
ORDER BY (r_reason_sk);

CREATE TABLE ship_mode (
    sm_ship_mode_sk           BIGINT NOT NULL,
    sm_ship_mode_id           CHAR(16) NOT NULL,
    sm_type                   CHAR(30),
    sm_code                   CHAR(10),
    sm_carrier                CHAR(20),
    sm_contract               CHAR(20))
ORDER BY (sm_ship_mode_sk);

CREATE TABLE store_returns (
    sr_returned_date_sk       INT,
    sr_return_time_sk         INT,
    sr_item_sk                BIGINT NOT NULL,
    sr_customer_sk            BIGINT,
    sr_cdemo_sk               BIGINT,
    sr_hdemo_sk               BIGINT,
    sr_addr_sk                BIGINT,
    sr_store_sk               BIGINT,
    sr_reason_sk              BIGINT,
    sr_ticket_number          BIGINT NOT NULL,
    sr_return_quantity        BIGINT,
    sr_return_amt             DECIMAL(7,2),
    sr_return_tax             DECIMAL(7,2),
    sr_return_amt_inc_tax     DECIMAL(7,2),
    sr_fee                    DECIMAL(7,2),
    sr_return_ship_cost       DECIMAL(7,2),
    sr_refunded_cash          DECIMAL(7,2),
    sr_reversed_charge        DECIMAL(7,2),
    sr_store_credit           DECIMAL(7,2),
    sr_net_loss               DECIMAL(7,2))
ORDER BY (sr_item_sk, sr_ticket_number);

CREATE TABLE store_sales (
    ss_sold_date_sk           INT,
    ss_sold_time_sk           INT,
    ss_item_sk                BIGINT NOT NULL,
    ss_customer_sk            BIGINT,
    ss_cdemo_sk               BIGINT,
    ss_hdemo_sk               BIGINT,
    ss_addr_sk                BIGINT,
    ss_store_sk               BIGINT,
    ss_promo_sk               BIGINT,
    ss_ticket_number          BIGINT NOT NULL,
    ss_quantity               BIGINT,
    ss_wholesale_cost         DECIMAL(7,2),
    ss_list_price             DECIMAL(7,2),
    ss_sales_price            DECIMAL(7,2),
    ss_ext_discount_amt       DECIMAL(7,2),
    ss_ext_sales_price        DECIMAL(7,2),
    ss_ext_wholesale_cost     DECIMAL(7,2),
    ss_ext_list_price         DECIMAL(7,2),
    ss_ext_tax                DECIMAL(7,2),
    ss_coupon_amt             DECIMAL(7,2),
    ss_net_paid               DECIMAL(7,2),
    ss_net_paid_inc_tax       DECIMAL(7,2),
    ss_net_profit             DECIMAL(7,2))
ORDER BY (ss_item_sk, ss_ticket_number);

CREATE TABLE store (
    s_store_sk                BIGINT NOT NULL,
    s_store_id                CHAR(16) NOT NULL,
    s_rec_start_date          DATE,
    s_rec_end_date            DATE,
    s_closed_date_sk          INT,
    s_store_name              VARCHAR(50),
    s_number_employees        BIGINT,
    s_floor_space             BIGINT,
    s_hours                   CHAR(20),
    s_manager                 VARCHAR(40),
    s_market_id               BIGINT,
    s_geography_class         VARCHAR(100),
    s_market_desc             VARCHAR(100),
    s_market_manager          VARCHAR(40),
    s_division_id             BIGINT,
    s_division_name           VARCHAR(50),
    s_company_id              BIGINT,
    s_company_name            VARCHAR(50),
    s_street_number           VARCHAR(10),
    s_street_name             VARCHAR(60),
    s_street_type             CHAR(15),
    s_suite_number            CHAR(10),
    s_city                    VARCHAR(60),
    s_county                  VARCHAR(30),
    s_state                   CHAR(2),
    s_zip                     CHAR(10),
    s_country                 VARCHAR(20),
    s_gmt_offset              DECIMAL(5,2),
    s_tax_percentage          DECIMAL(5,2))
ORDER BY (s_store_sk);

CREATE TABLE time_dim (
    t_time_sk                 INT NOT NULL,
    t_time_id                 CHAR(16) NOT NULL,
    t_time                    BIGINT NOT NULL,
    t_hour                    BIGINT,
    t_minute                  BIGINT,
    t_second                  BIGINT,
    t_am_pm                   CHAR(2),
    t_shift                   CHAR(20),
    t_sub_shift               CHAR(20),
    t_meal_time               CHAR(20))
ORDER BY (t_time_sk);

CREATE TABLE warehouse (
    w_warehouse_sk            BIGINT NOT NULL,
    w_warehouse_id            CHAR(16) NOT NULL,
    w_warehouse_name          VARCHAR(20),
    w_warehouse_sq_ft         BIGINT,
    w_street_number           CHAR(10),
    w_street_name             VARCHAR(60),
    w_street_type             CHAR(15),
    w_suite_number            CHAR(10),
    w_city                    VARCHAR(60),
    w_county                  VARCHAR(30),
    w_state                   CHAR(2),
    w_zip                     CHAR(10),
    w_country                 VARCHAR(20),
    w_gmt_offset              DECIMAL(5,2))
ORDER BY (w_warehouse_sk);

CREATE TABLE web_page (
    wp_web_page_sk            BIGINT NOT NULL,
    wp_web_page_id            CHAR(16) NOT NULL,
    wp_rec_start_date         DATE,
    wp_rec_end_date           DATE,
    wp_creation_date_sk       INT,
    wp_access_date_sk         INT,
    wp_autogen_flag           CHAR(1),
    wp_customer_sk            BIGINT,
    wp_url                    VARCHAR(100),
    wp_type                   CHAR(50),
    wp_char_count             BIGINT,
    wp_link_count             BIGINT,
    wp_image_count            BIGINT,
    wp_max_ad_count           BIGINT)
ORDER BY (wp_web_page_sk);

CREATE TABLE web_returns (
    wr_returned_date_sk       INT,
    wr_returned_time_sk       INT,
    wr_item_sk                BIGINT NOT NULL,
    wr_refunded_customer_sk   BIGINT,
    wr_refunded_cdemo_sk      BIGINT,
    wr_refunded_hdemo_sk      BIGINT,
    wr_refunded_addr_sk       BIGINT,
    wr_returning_customer_sk  BIGINT,
    wr_returning_cdemo_sk     BIGINT,
    wr_returning_hdemo_sk     BIGINT,
    wr_returning_addr_sk      BIGINT,
    wr_web_page_sk            BIGINT,
    wr_reason_sk              BIGINT,
    wr_order_number           BIGINT NOT NULL,
    wr_return_quantity        BIGINT,
    wr_return_amt             DECIMAL(7,2),
    wr_return_tax             DECIMAL(7,2),
    wr_return_amt_inc_tax     DECIMAL(7,2),
    wr_fee                    DECIMAL(7,2),
    wr_return_ship_cost       DECIMAL(7,2),
    wr_refunded_cash          DECIMAL(7,2),
    wr_reversed_charge        DECIMAL(7,2),
    wr_account_credit         DECIMAL(7,2),
    wr_net_loss               DECIMAL(7,2))
ORDER BY (wr_item_sk, wr_order_number);

CREATE TABLE web_sales (
    ws_sold_date_sk           INT,
    ws_sold_time_sk           INT,
    ws_ship_date_sk           INT,
    ws_item_sk                BIGINT NOT NULL,
    ws_bill_customer_sk       BIGINT,
    ws_bill_cdemo_sk          BIGINT,
    ws_bill_hdemo_sk          BIGINT,
    ws_bill_addr_sk           BIGINT,
    ws_ship_customer_sk       BIGINT,
    ws_ship_cdemo_sk          BIGINT,
    ws_ship_hdemo_sk          BIGINT,
    ws_ship_addr_sk           BIGINT,
    ws_web_page_sk            BIGINT,
    ws_web_site_sk            BIGINT,
    ws_ship_mode_sk           BIGINT,
    ws_warehouse_sk           BIGINT,
    ws_promo_sk               BIGINT,
    ws_order_number           BIGINT NOT NULL,
    ws_quantity               BIGINT,
    ws_wholesale_cost         DECIMAL(7,2),
    ws_list_price             DECIMAL(7,2),
    ws_sales_price            DECIMAL(7,2),
    ws_ext_discount_amt       DECIMAL(7,2),
    ws_ext_sales_price        DECIMAL(7,2),
    ws_ext_wholesale_cost     DECIMAL(7,2),
    ws_ext_list_price         DECIMAL(7,2),
    ws_ext_tax                DECIMAL(7,2),
    ws_coupon_amt             DECIMAL(7,2),
    ws_ext_ship_cost          DECIMAL(7,2),
    ws_net_paid               DECIMAL(7,2),
    ws_net_paid_inc_tax       DECIMAL(7,2),
    ws_net_paid_inc_ship      DECIMAL(7,2),
    ws_net_paid_inc_ship_tax  DECIMAL(7,2),
    ws_net_profit             DECIMAL(7,2))
ORDER BY (ws_item_sk, ws_order_number);

CREATE TABLE web_site (
    web_site_sk               BIGINT NOT NULL,
    web_site_id               CHAR(16) NOT NULL,
    web_rec_start_date        DATE,
    web_rec_end_date          DATE,
    web_name                  VARCHAR(50),
    web_open_date_sk          INT,
    web_close_date_sk         INT,
    web_class                 VARCHAR(50),
    web_manager               VARCHAR(40),
    web_mkt_id                BIGINT,
    web_mkt_class             VARCHAR(50),
    web_mkt_desc              VARCHAR(100),
    web_market_manager        VARCHAR(40),
    web_company_id            BIGINT,
    web_company_name          CHAR(50),
    web_street_number         CHAR(10),
    web_street_name           VARCHAR(60),
    web_street_type           CHAR(15),
    web_suite_number          CHAR(10),
    web_city                  VARCHAR(60),
    web_county                VARCHAR(30),
    web_state                 CHAR(2),
    web_zip                   CHAR(10),
    web_country               VARCHAR(20),
    web_gmt_offset            DECIMAL(5,2),
    web_tax_percentage        DECIMAL(5,2))
ORDER BY (web_site_sk);
