/*
  Staging layer: keeps the source data EXACTLY as received.

  Conventions for every stg table:
  - stg_row_id   : row id within the load, so clean.rejected_records can point back to the exact bad row.
  - load_date    : start time of the load batch (same value for the whole batch, easy to trace).
  - source_system: source system.
  - No primary keys or business constraints: stg must accept bad data too (duplicate keys, NULLs, negatives),
    otherwise errors are blocked at load time and leave no trace.
  - Database sources keep their source types. File/API sources are all strings, because
    type conversion is the clean layer's job.

  stg is fully reloaded on every run, so DROP/CREATE here is safe.
*/
DROP TABLE IF EXISTS stg.crm_customers;
CREATE TABLE stg.crm_customers (
    stg_row_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    customer_id     NVARCHAR(20)  NULL,
    gender          NVARCHAR(20)  NULL,
    senior_citizen  INT           NULL,
    partner         NVARCHAR(10)  NULL,
    dependents      NVARCHAR(10)  NULL,
    created_at      DATETIME2(0)  NULL,
    updated_at      DATETIME2(0)  NULL,
    load_date       DATETIME2(0)  NOT NULL,
    source_system   NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.crm_contracts;
CREATE TABLE stg.crm_contracts (
    stg_row_id        BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    contract_id       NVARCHAR(20)  NULL,
    customer_id       NVARCHAR(20)  NULL,
    contract_type     NVARCHAR(40)  NULL,
    paperless_billing NVARCHAR(10)  NULL,
    payment_method    NVARCHAR(60)  NULL,
    monthly_charges   DECIMAL(10,2) NULL,
    total_charges     NVARCHAR(20)  NULL,
    tenure_months     INT           NULL,
    start_date        NVARCHAR(30)  NULL,
    end_date          NVARCHAR(30)  NULL,
    contract_status   NVARCHAR(20)  NULL,
    churn_flag        NVARCHAR(10)  NULL,
    load_date         DATETIME2(0)  NOT NULL,
    source_system     NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.crm_services;
CREATE TABLE stg.crm_services (
    stg_row_id         BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    customer_id        NVARCHAR(20) NULL,
    phone_service      NVARCHAR(30) NULL,
    multiple_lines     NVARCHAR(30) NULL,
    internet_service   NVARCHAR(30) NULL,
    online_security    NVARCHAR(30) NULL,
    online_backup      NVARCHAR(30) NULL,
    device_protection  NVARCHAR(30) NULL,
    tech_support       NVARCHAR(30) NULL,
    streaming_tv       NVARCHAR(30) NULL,
    streaming_movies   NVARCHAR(30) NULL,
    load_date          DATETIME2(0) NOT NULL,
    source_system      NVARCHAR(30) NOT NULL
);

DROP TABLE IF EXISTS stg.billing_invoices;
CREATE TABLE stg.billing_invoices (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    invoice_id     NVARCHAR(30)  NULL,
    customer_id    NVARCHAR(30)  NULL,
    billing_month  DATE          NULL,
    invoice_date   DATE          NULL,
    due_date       DATE          NULL,
    amount_usd     DECIMAL(10,2) NULL,
    currency       CHAR(3)       NULL,
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.billing_payments;
CREATE TABLE stg.billing_payments (
    stg_row_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    payment_id      NVARCHAR(20)  NULL,
    invoice_id      NVARCHAR(30)  NULL,
    customer_id     NVARCHAR(30)  NULL,
    payment_date    DATE          NULL,
    amount_usd      DECIMAL(10,2) NULL,
    payment_method  NVARCHAR(60)  NULL,
    load_date       DATETIME2(0)  NOT NULL,
    source_system   NVARCHAR(30)  NOT NULL
);

/*
  Hand-typed Excel file: column positions and names change between sheets and between submissions.
  Stored in long form (1 row = 1 cell) with the original header, so column detection rules live in the clean layer
  and the loader does not need changing whenever Finance renames a header.
*/
DROP TABLE IF EXISTS stg.finance_targets_cells;
CREATE TABLE stg.finance_targets_cells (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    source_file    NVARCHAR(260) NOT NULL,
    sheet_name     NVARCHAR(100) NOT NULL,
    excel_row      INT           NOT NULL,
    column_letter  VARCHAR(3)    NOT NULL,
    header_text    NVARCHAR(200) NULL,   -- original header, whitespace and diacritics kept
    cell_value     NVARCHAR(400) NULL,   -- cell value as text
    cell_type      VARCHAR(20)   NULL,   -- type stored by Excel (number/datetime/string) so clean knows how to convert
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.ticket_support_tickets;
CREATE TABLE stg.ticket_support_tickets (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    source_file    NVARCHAR(260) NOT NULL,
    source_line    INT           NOT NULL,   -- line number in the CSV file (header = 1)
    ticket_id      NVARCHAR(100) NULL,
    customer_id    NVARCHAR(100) NULL,
    created_at     NVARCHAR(100) NULL,
    category       NVARCHAR(100) NULL,
    priority       NVARCHAR(100) NULL,
    channel        NVARCHAR(100) NULL,
    status         NVARCHAR(100) NULL,
    resolved_at    NVARCHAR(100) NULL,
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.api_fx_rates;
CREATE TABLE stg.api_fx_rates (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    rate_month     NVARCHAR(20)   NULL,
    rate_date      NVARCHAR(20)   NULL,
    usd_vnd        NVARCHAR(50)   NULL,
    provider       NVARCHAR(100)  NULL,
    granularity    NVARCHAR(30)   NULL,
    raw_json       NVARCHAR(1000) NULL,  -- original API record, kept for reconciliation
    load_date      DATETIME2(0)   NOT NULL,
    source_system  NVARCHAR(30)   NOT NULL
);
