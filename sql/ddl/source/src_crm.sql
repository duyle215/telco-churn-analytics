/*
  Simulated source system: CRM (database src_crm).

  Deliberately "loose", like an old CRM:
  - customers has NO primary key on customer_id, which is how duplicate customers appear.
  - Yes/No and date columns are NVARCHAR because the entry screens do not enforce a format.
  - total_charges stays text as in the original file (has blank values).
  The warehouse (TelcoDW) has to handle these problems itself instead of expecting clean sources.
*/
CREATE TABLE dbo.customers (
    customer_id     NVARCHAR(20)  NOT NULL,
    gender          NVARCHAR(20)  NULL,
    senior_citizen  INT           NULL,     -- the original data uses 0/1, unlike the Yes/No convention of other columns
    partner         NVARCHAR(10)  NULL,
    dependents      NVARCHAR(10)  NULL,
    created_at      DATETIME2(0)  NULL,
    updated_at      DATETIME2(0)  NULL
);
GO

CREATE TABLE dbo.contracts (
    contract_id       NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id       NVARCHAR(20)  NOT NULL,
    contract_type     NVARCHAR(40)  NULL,
    paperless_billing NVARCHAR(10)  NULL,
    payment_method    NVARCHAR(60)  NULL,
    monthly_charges   DECIMAL(10,2) NULL,  -- current plan price (as of the last billed month)
    total_charges     NVARCHAR(20)  NULL,  -- running total recorded in CRM, not reconciled with billing
    tenure_months     INT           NULL,
    start_date        NVARCHAR(30)  NULL,
    end_date          NVARCHAR(30)  NULL,
    contract_status   NVARCHAR(20)  NULL,
    churn_flag        NVARCHAR(10)  NULL
);
GO

CREATE TABLE dbo.services (
    customer_id        NVARCHAR(20) NOT NULL,
    phone_service      NVARCHAR(30) NULL,
    multiple_lines     NVARCHAR(30) NULL,
    internet_service   NVARCHAR(30) NULL,
    online_security    NVARCHAR(30) NULL,
    online_backup      NVARCHAR(30) NULL,
    device_protection  NVARCHAR(30) NULL,
    tech_support       NVARCHAR(30) NULL,
    streaming_tv       NVARCHAR(30) NULL,
    streaming_movies   NVARCHAR(30) NULL
);
GO
