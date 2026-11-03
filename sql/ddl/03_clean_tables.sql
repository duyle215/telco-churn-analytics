/*
  Clean layer: typed, trimmed, de-duplicated, key-checked data.
  Unusable rows are NOT silently deleted; they move to clean.rejected_records with a reason.
  Deploy script: recreates the tables. The stored procedures TRUNCATE and reload, so repeated runs stay correct.
*/
DROP TABLE IF EXISTS clean.customers;
CREATE TABLE clean.customers (
    customer_id        NVARCHAR(20) NOT NULL PRIMARY KEY,
    gender             NVARCHAR(10) NOT NULL,
    is_senior_citizen  BIT          NOT NULL,
    has_partner        BIT          NOT NULL,
    has_dependents     BIT          NOT NULL,
    created_at         DATETIME2(0) NULL,
    updated_at         DATETIME2(0) NULL,
    stg_row_id         BIGINT       NOT NULL
);

DROP TABLE IF EXISTS clean.contracts;
CREATE TABLE clean.contracts (
    contract_id          NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id          NVARCHAR(20)  NOT NULL UNIQUE,
    contract_type        NVARCHAR(20)  NOT NULL,
    is_paperless_billing BIT           NOT NULL,
    payment_method       NVARCHAR(30)  NOT NULL,
    monthly_charges      DECIMAL(10,2) NOT NULL,
    total_charges        DECIMAL(12,2) NULL,      -- NULL is valid when tenure = 0 (nothing billed yet)
    tenure_months        INT           NOT NULL,
    start_date           DATE          NOT NULL,
    end_date             DATE          NULL,
    contract_status      NVARCHAR(20)  NOT NULL,
    is_churned           BIT           NOT NULL,
    churn_month          DATE          NULL,
    first_billing_month  DATE          NULL,      -- month after signup (billed in arrears), NULL if tenure = 0
    last_billing_month   DATE          NULL,      -- exit month, or snapshot month if still active
    stg_row_id           BIGINT        NOT NULL
);

DROP TABLE IF EXISTS clean.services;
CREATE TABLE clean.services (
    customer_id        NVARCHAR(20) NOT NULL PRIMARY KEY,
    phone_service      NVARCHAR(30) NOT NULL,
    multiple_lines     NVARCHAR(30) NOT NULL,
    internet_service   NVARCHAR(30) NOT NULL,
    online_security    NVARCHAR(30) NOT NULL,
    online_backup      NVARCHAR(30) NOT NULL,
    device_protection  NVARCHAR(30) NOT NULL,
    tech_support       NVARCHAR(30) NOT NULL,
    streaming_tv       NVARCHAR(30) NOT NULL,
    streaming_movies   NVARCHAR(30) NOT NULL,
    stg_row_id         BIGINT       NOT NULL
);

DROP TABLE IF EXISTS clean.invoices;
CREATE TABLE clean.invoices (
    invoice_id     NVARCHAR(30)  NOT NULL PRIMARY KEY,
    customer_id    NVARCHAR(20)  NOT NULL,
    billing_month  DATE          NOT NULL,
    invoice_date   DATE          NOT NULL,
    due_date       DATE          NOT NULL,
    amount_usd     DECIMAL(10,2) NOT NULL,
    -- SOURCE / SIGN_CORRECTED / FROM_PAYMENT / IMPUTED_PREV_INVOICE / IMPUTED_NEXT_INVOICE / IMPUTED_CONTRACT_PRICE
    amount_source  VARCHAR(30)   NOT NULL,
    stg_row_id     BIGINT        NOT NULL,
    CONSTRAINT uq_clean_invoices_customer_month UNIQUE (customer_id, billing_month)
);

DROP TABLE IF EXISTS clean.payments;
CREATE TABLE clean.payments (
    payment_id      NVARCHAR(20)  NOT NULL PRIMARY KEY,
    invoice_id      NVARCHAR(30)  NOT NULL,
    customer_id     NVARCHAR(20)  NOT NULL,
    payment_date    DATE          NOT NULL,
    amount_usd      DECIMAL(10,2) NOT NULL,
    payment_method  NVARCHAR(30)  NOT NULL,
    days_after_due  INT           NOT NULL,      -- negative = paid early
    is_late         BIT           NOT NULL,
    stg_row_id      BIGINT        NOT NULL,
    INDEX ix_clean_payments_invoice (invoice_id)
);

DROP TABLE IF EXISTS clean.tickets;
CREATE TABLE clean.tickets (
    ticket_id         NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id       NVARCHAR(20)  NOT NULL,
    created_at        DATETIME2(0)  NOT NULL,
    resolved_at       DATETIME2(0)  NULL,
    category          NVARCHAR(30)  NOT NULL,
    priority          NVARCHAR(10)  NOT NULL,
    channel           NVARCHAR(10)  NOT NULL,
    status            NVARCHAR(10)  NOT NULL,
    resolution_hours  DECIMAL(10,2) NULL,
    stg_row_id        BIGINT        NOT NULL
);

DROP TABLE IF EXISTS clean.targets;
CREATE TABLE clean.targets (
    target_month       DATE           NOT NULL PRIMARY KEY,
    churn_rate_target  DECIMAL(9,6)   NOT NULL,   -- ratio (0.0139), converted from the percent unit used in the Excel file
    mrr_target_usd     DECIMAL(14,2)  NOT NULL,
    note               NVARCHAR(400)  NULL,
    sheet_name         NVARCHAR(100)  NOT NULL,
    excel_row          INT            NOT NULL
);

DROP TABLE IF EXISTS clean.fx_rates;
CREATE TABLE clean.fx_rates (
    rate_month   DATE           NOT NULL PRIMARY KEY,
    usd_vnd      DECIMAL(18,4)  NOT NULL,
    rate_date    DATE           NOT NULL,
    provider     NVARCHAR(100)  NOT NULL,
    granularity  NVARCHAR(30)   NOT NULL
);

DROP TABLE IF EXISTS clean.rejected_records;
CREATE TABLE clean.rejected_records (
    reject_id      BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id       UNIQUEIDENTIFIER NOT NULL,
    source_table   NVARCHAR(128)    NOT NULL,
    stg_row_id     BIGINT           NULL,
    business_key   NVARCHAR(100)    NULL,
    reason_code    VARCHAR(50)      NOT NULL,
    reason_detail  NVARCHAR(400)    NULL,
    raw_record     NVARCHAR(MAX)    NULL,     -- the whole stg row as JSON, for tracing
    rejected_at    DATETIME2(0)     NOT NULL,
    INDEX ix_rejected_source (source_table, reason_code)
);
