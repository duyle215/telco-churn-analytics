/*
  Tầng mart: star schema cho phân tích và Power BI.

  - Dimension nạp bằng MERGE (SCD type 1): surrogate key giữ ổn định qua các lần chạy,
    nên báo cáo/bookmark trỏ theo key không bị lệch.
  - Fact nạp lại toàn bộ (TRUNCATE + INSERT): dữ liệu nhỏ, đơn giản và chắc chắn hơn incremental.
  - Có khoá ngoại fact -> dim để database tự chặn dòng fact mồ côi.
*/
DROP TABLE IF EXISTS mart.customer_factor;
DROP TABLE IF EXISTS mart.dim_factor;
DROP TABLE IF EXISTS mart.customer_snapshot;
DROP TABLE IF EXISTS mart.fact_billing;
DROP TABLE IF EXISTS mart.fact_tickets;
DROP TABLE IF EXISTS mart.fact_target;
DROP TABLE IF EXISTS mart.dq_check_results;
DROP TABLE IF EXISTS mart.dim_customer;
DROP TABLE IF EXISTS mart.dim_contract;
DROP TABLE IF EXISTS mart.dim_service;
DROP TABLE IF EXISTS mart.dim_payment_method;
DROP TABLE IF EXISTS mart.dim_date;
GO

CREATE TABLE mart.dim_date (
    date_key            INT          NOT NULL PRIMARY KEY,   -- yyyymmdd
    [date]              DATE         NOT NULL UNIQUE,
    [year]              SMALLINT     NOT NULL,
    quarter             TINYINT      NOT NULL,
    quarter_label       CHAR(2)      NOT NULL,               -- Q1..Q4
    year_quarter        CHAR(7)      NOT NULL,               -- 2025-Q1
    [month]             TINYINT      NOT NULL,
    month_name          VARCHAR(10)  NOT NULL,
    month_short         CHAR(3)      NOT NULL,
    year_month          CHAR(7)      NOT NULL,               -- 2025-03
    year_month_key      INT          NOT NULL,               -- 202503, dùng để sắp xếp year_month
    month_start_date    DATE         NOT NULL,
    month_end_date      DATE         NOT NULL,
    month_index         INT          NOT NULL,               -- số tháng kể từ tháng đầu của lịch
    day_of_month        TINYINT      NOT NULL,
    day_of_week         TINYINT      NOT NULL,               -- 1 = Thứ hai
    day_name            VARCHAR(10)  NOT NULL,
    iso_week            TINYINT      NOT NULL,
    is_weekend          BIT          NOT NULL,
    is_month_start      BIT          NOT NULL,
    is_analysis_window  BIT          NOT NULL,               -- 2024-01..2025-12: chỉ ở đây churn mới có ý nghĩa
    is_snapshot_month   BIT          NOT NULL
);

CREATE TABLE mart.dim_customer (
    customer_key            INT IDENTITY(1,1) PRIMARY KEY,
    customer_id             NVARCHAR(20)  NOT NULL UNIQUE,
    gender                  NVARCHAR(10)  NOT NULL,
    senior_citizen          NVARCHAR(3)   NOT NULL,
    partner                 NVARCHAR(3)   NOT NULL,
    dependents              NVARCHAR(3)   NOT NULL,
    signup_date             DATE          NULL,
    signup_month            DATE          NULL,     -- cohort
    tenure_months           INT           NULL,
    tenure_group            NVARCHAR(20)  NULL,
    tenure_group_order      TINYINT       NULL,
    customer_status         NVARCHAR(20)  NOT NULL, -- Active / Churned / New (not billed)
    churn_date              DATE          NULL,
    churn_month             DATE          NULL,
    first_billing_month     DATE          NULL,
    last_billing_month      DATE          NULL,
    current_monthly_charges DECIMAL(10,2) NULL
);

CREATE TABLE mart.dim_contract (
    contract_key          INT IDENTITY(1,1) PRIMARY KEY,
    contract_type         NVARCHAR(20) NOT NULL,
    paperless_billing     NVARCHAR(3)  NOT NULL,
    contract_term_months  TINYINT      NOT NULL,
    contract_sort         TINYINT      NOT NULL,
    CONSTRAINT uq_dim_contract UNIQUE (contract_type, paperless_billing)
);

CREATE TABLE mart.dim_payment_method (
    payment_method_key  INT IDENTITY(1,1) PRIMARY KEY,
    payment_method      NVARCHAR(30) NOT NULL UNIQUE,
    payment_type        NVARCHAR(10) NOT NULL,   -- Automatic / Manual
    is_automatic        BIT          NOT NULL
);

/* Junk dimension: mỗi dòng là một tổ hợp dịch vụ khác nhau, tránh nhồi 9 cột dịch vụ vào fact. */
CREATE TABLE mart.dim_service (
    service_key         INT IDENTITY(1,1) PRIMARY KEY,
    phone_service       NVARCHAR(30) NOT NULL,
    multiple_lines      NVARCHAR(30) NOT NULL,
    internet_service    NVARCHAR(30) NOT NULL,
    online_security     NVARCHAR(30) NOT NULL,
    online_backup       NVARCHAR(30) NOT NULL,
    device_protection   NVARCHAR(30) NOT NULL,
    tech_support        NVARCHAR(30) NOT NULL,
    streaming_tv        NVARCHAR(30) NOT NULL,
    streaming_movies    NVARCHAR(30) NOT NULL,
    addon_count         TINYINT      NOT NULL,   -- số dịch vụ internet đi kèm đang dùng (0..6)
    has_streaming       NVARCHAR(3)  NOT NULL,
    internet_sort       TINYINT      NOT NULL,
    CONSTRAINT uq_dim_service UNIQUE (phone_service, multiple_lines, internet_service, online_security, online_backup,
                                      device_protection, tech_support, streaming_tv, streaming_movies)
);

/* Grain: 1 khách x 1 tháng có tính cước. */
CREATE TABLE mart.fact_billing (
    customer_key        INT           NOT NULL REFERENCES mart.dim_customer (customer_key),
    date_key            INT           NOT NULL REFERENCES mart.dim_date (date_key),  -- ngày đầu tháng
    contract_key        INT           NOT NULL REFERENCES mart.dim_contract (contract_key),
    service_key         INT           NOT NULL REFERENCES mart.dim_service (service_key),
    payment_method_key  INT           NOT NULL REFERENCES mart.dim_payment_method (payment_method_key),
    invoice_id          NVARCHAR(30)  NULL,      -- NULL khi tháng không có hoá đơn (sự cố billing)
    tenure_month_no     SMALLINT      NOT NULL,
    amount_usd          DECIMAL(10,2) NOT NULL,
    usd_vnd_rate        DECIMAL(18,4) NOT NULL,
    amount_vnd          DECIMAL(18,0) NOT NULL,
    amount_source       VARCHAR(30)   NOT NULL,
    is_imputed          BIT           NOT NULL,
    is_first_month      BIT           NOT NULL,
    is_churn_month      BIT           NOT NULL,
    is_paid             BIT           NULL,      -- NULL khi không có hoá đơn để đối chiếu
    paid_amount_usd     DECIMAL(10,2) NULL,
    payment_date        DATE          NULL,
    days_after_due      INT           NULL,
    is_late             BIT           NULL,
    CONSTRAINT pk_fact_billing PRIMARY KEY (customer_key, date_key)
);

/* Grain: 1 ticket. */
CREATE TABLE mart.fact_tickets (
    ticket_id                   NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_key                INT           NOT NULL REFERENCES mart.dim_customer (customer_key),
    created_date_key            INT           NOT NULL REFERENCES mart.dim_date (date_key),
    resolved_date_key           INT           NULL REFERENCES mart.dim_date (date_key),
    contract_key                INT           NOT NULL REFERENCES mart.dim_contract (contract_key),
    service_key                 INT           NOT NULL REFERENCES mart.dim_service (service_key),
    payment_method_key          INT           NOT NULL REFERENCES mart.dim_payment_method (payment_method_key),
    created_at                  DATETIME2(0)  NOT NULL,
    resolved_at                 DATETIME2(0)  NULL,
    category                    NVARCHAR(30)  NOT NULL,
    priority                    NVARCHAR(10)  NOT NULL,
    channel                     NVARCHAR(10)  NOT NULL,
    status                      NVARCHAR(10)  NOT NULL,
    resolution_hours            DECIMAL(10,2) NULL,
    is_open                     BIT           NOT NULL,
    days_before_churn           INT           NULL,
    is_within_90d_before_churn  BIT           NOT NULL
);

/* Grain: 1 tháng. */
CREATE TABLE mart.fact_target (
    date_key           INT           NOT NULL PRIMARY KEY REFERENCES mart.dim_date (date_key),
    churn_rate_target  DECIMAL(9,6)  NOT NULL,
    mrr_target_usd     DECIMAL(14,2) NOT NULL,
    note               NVARCHAR(400) NULL
);

/* Kết quả kiểm tra chất lượng dữ liệu theo từng batch, nguồn cho trang Data Quality. */
CREATE TABLE mart.dq_check_results (
    dq_id           BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id        UNIQUEIDENTIFIER NOT NULL,
    check_id        VARCHAR(40)      NOT NULL,
    check_group     NVARCHAR(50)     NOT NULL,
    check_name      NVARCHAR(200)    NOT NULL,
    object_name     NVARCHAR(200)    NULL,
    value_before    DECIMAL(18,2)    NULL,   -- đo trên stg
    value_after     DECIMAL(18,2)    NULL,   -- đo trên clean/mart
    value_rejected  DECIMAL(18,2)    NULL,
    expected_rule   NVARCHAR(300)    NULL,
    status          VARCHAR(10)      NOT NULL CHECK (status IN ('PASS', 'WARN', 'FAIL')),
    note            NVARCHAR(1000)   NULL,
    checked_at      DATETIME2(0)     NOT NULL
);

/*
  Grain: 1 khách có tính cước, chụp tại snapshot (hồ sơ hiện tại + hành vi tổng hợp).
  Bản vật lý hoá của mart.v_customer_profile: view đó phải gom 228 nghìn dòng fact mỗi lần đọc (~2-3 giây),
  trong khi trang Khám phá truy vấn lại mỗi khi người dùng bật/tắt bộ lọc. Nạp lại cuối mỗi batch ETL.
*/
CREATE TABLE mart.customer_snapshot (
    customer_key            INT           NOT NULL PRIMARY KEY REFERENCES mart.dim_customer (customer_key),
    customer_id             NVARCHAR(20)  NOT NULL,
    gender                  NVARCHAR(10)  NOT NULL,
    senior_citizen          NVARCHAR(3)   NOT NULL,
    partner                 NVARCHAR(3)   NOT NULL,
    dependents              NVARCHAR(3)   NOT NULL,
    signup_month            DATE          NULL,
    first_billing_month     DATE          NULL,
    tenure_months           INT           NULL,
    tenure_group            NVARCHAR(20)  NULL,
    tenure_group_order      TINYINT       NULL,
    customer_status         NVARCHAR(20)  NOT NULL,
    churn_month             DATE          NULL,
    is_churned              INT           NOT NULL,
    contract_type           NVARCHAR(20)  NOT NULL,
    contract_sort           TINYINT       NOT NULL,
    paperless_billing       NVARCHAR(3)   NOT NULL,
    internet_service        NVARCHAR(30)  NOT NULL,
    phone_service           NVARCHAR(30)  NOT NULL,
    tech_support            NVARCHAR(30)  NOT NULL,
    online_security         NVARCHAR(30)  NOT NULL,
    online_backup           NVARCHAR(30)  NOT NULL,
    device_protection       NVARCHAR(30)  NOT NULL,
    addon_count             TINYINT       NOT NULL,
    has_streaming           NVARCHAR(3)   NOT NULL,
    payment_method          NVARCHAR(30)  NOT NULL,
    payment_type            NVARCHAR(10)  NOT NULL,
    risk_segment            NVARCHAR(100) NOT NULL,
    last_billed_amount_usd  DECIMAL(10,2) NOT NULL,
    current_mrr_usd         DECIMAL(10,2) NULL,
    billed_months           INT           NOT NULL,
    window_months           INT           NOT NULL,
    lifetime_revenue_usd    DECIMAL(14,2) NOT NULL,
    late_payment_rate       DECIMAL(6,4)  NULL,
    tickets                 INT           NOT NULL,
    billing_tickets         INT           NOT NULL,
    technical_tickets       INT           NOT NULL,
    in_analysis_window      INT           NOT NULL
);

/*
  Phục vụ lọc động trên trang Khám phá (bridge/EAV): 1 dòng = 1 khách x 1 yếu tố, kèm giá trị của khách ở yếu tố đó.
  Nhờ vậy bộ lọc tuỳ ý (nhiều yếu tố, nhiều giá trị) chỉ là một phép join với bảng bộ lọc,
  không phải sinh SQL động theo từng tổ hợp cột.
*/
CREATE TABLE mart.dim_factor (
    factor_key    VARCHAR(30)   NOT NULL PRIMARY KEY,
    factor_label  NVARCHAR(60)  NOT NULL,
    factor_sort   TINYINT       NOT NULL
);

CREATE TABLE mart.customer_factor (
    customer_key  INT           NOT NULL REFERENCES mart.customer_snapshot (customer_key),
    factor_key    VARCHAR(30)   NOT NULL REFERENCES mart.dim_factor (factor_key),
    value         NVARCHAR(60)  NOT NULL,
    value_sort    INT           NOT NULL,
    CONSTRAINT pk_customer_factor PRIMARY KEY (customer_key, factor_key)
);

/*
  Columnstore cho bảng fact: các truy vấn phân tích chỉ đọc vài cột nhưng gom trên toàn bảng,
  columnstore nén theo cột và cho phép batch mode nên nhanh hơn nhiều so với quét theo dòng.
*/
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_fact_billing
    ON mart.fact_billing (customer_key, date_key, is_churn_month, is_first_month, amount_usd);
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_fact_tickets
    ON mart.fact_tickets (customer_key, created_date_key, category);
-- Bảng cầu nối 91 nghìn dòng được join + gom nhóm mỗi lần người dùng đổi bộ lọc; batch mode
-- giảm bước tính tác động từng yếu tố từ ~260 ms xuống ~35 ms (đo bằng sys.dm_exec_query_stats).
CREATE NONCLUSTERED COLUMNSTORE INDEX ncci_customer_factor
    ON mart.customer_factor (customer_key, factor_key, value, value_sort);
