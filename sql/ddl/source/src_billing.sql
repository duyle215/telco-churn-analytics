/*
  Simulated source system: Billing/ERP (database src_billing).

  Billing is a separate system that stores customer_id as plain text with NO foreign key to CRM
  (different database, different vendor). Invoices can therefore exist for customers
  missing from CRM, and key reconciliation is the DW's job.
  amount_usd allows NULL because integration errors sometimes send invoices without an amount.
*/
CREATE TABLE dbo.invoices (
    invoice_id     NVARCHAR(30)  NOT NULL PRIMARY KEY,
    customer_id    NVARCHAR(30)  NOT NULL,
    billing_month  DATE          NOT NULL,  -- first day of the billing period
    invoice_date   DATE          NOT NULL,  -- invoiced at period end (billed in arrears)
    due_date       DATE          NOT NULL,
    amount_usd     DECIMAL(10,2) NULL,
    currency       CHAR(3)       NOT NULL DEFAULT 'USD'
);
GO

CREATE TABLE dbo.payments (
    payment_id      NVARCHAR(20)  NOT NULL PRIMARY KEY,
    invoice_id      NVARCHAR(30)  NOT NULL,
    customer_id     NVARCHAR(30)  NOT NULL,
    payment_date    DATE          NOT NULL,
    amount_usd      DECIMAL(10,2) NOT NULL,
    payment_method  NVARCHAR(60)  NULL
);
GO
