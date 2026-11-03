# Stages 2-3: Data warehouse `TelcoDW`

## 1. Architecture and how to run it

```
src_crm / src_billing / targets.xlsx / support_tickets.csv / FX API
        │  python -m src.load_staging    (loaded as is, full reload)
        ▼
stg.*   ──  EXEC dbo.usp_run_etl  (python -m src.run_etl [--rebuild])
        ▼
clean.* + clean.rejected_records      (typed, de-duplicated, key-checked)
        ▼
mart.*  (star schema)  +  mart.dq_check_results
```

| Schema | Role | Load method |
|---|---|---|
| `stg` | As-is copy of the sources, plus `stg_row_id`, `load_date`, `source_system` | Full reload every run |
| `clean` | Cleaned data; bad rows go to `clean.rejected_records` with a reason and the original row as JSON | TRUNCATE + INSERT in 1 transaction |
| `mart` | Star schema for analysis/Power BI | Dimensions: MERGE (SCD1, stable keys). Facts: TRUNCATE + INSERT |
| `dbo` | `etl_log` (1 row per step), `etl_config` (snapshot_date, analysis_window_start) | |

Every stored procedure is idempotent and writes to `etl_log`. Verified: re-running without a rebuild gives the
same dimension keys, the same `fact_billing` checksum and the same rejected-row counts.

Code: [sql/ddl/](../sql/ddl/), [sql/etl/](../sql/etl/), [sql/quality/](../sql/quality/).

## 2. Cleaning rules (stg -> clean)

| Error | Handling | Result (latest batch) |
|---|---|---|
| Duplicate `customer_id` | TRIM, then keep the row with the latest `updated_at`; the others -> rejected `DUPLICATE_KEY`, stating whether it was an exact duplicate or an older version | 45 rows rejected |
| Yes/Y/yes/1, No/N/no/0 | `clean.fn_yes_no_to_bit` -> BIT; unknown values -> `INVALID_VALUE` | 1,694 values normalised |
| Extra whitespace | `LTRIM(RTRIM())` on keys and category columns; detected with `DATALENGTH` because `=` ignores trailing spaces | 910 values |
| Dates in several formats | `clean.fn_parse_datetime`: ISO, `dd/mm/yyyy` (day before month), `yyyymmdd`, `dd-Mon-yyyy [hh:mm AM]`; unreadable -> `INVALID_DATE` | 7,300 values, 0 parse failures |
| Negative amount | Sign flipped (`SIGN_CORRECTED`); verified: 116/116 paid invoices match the amount paid exactly | 120 rows |
| NULL amount | Taken from the payment (`FROM_PAYMENT`); if unpaid, from the previous/next invoice, finally the plan price | 148 from payments, 2 estimated |
| Invoices for customers missing from CRM | -> rejected `ORPHAN_CUSTOMER`; their payments -> `ORPHAN_INVOICE` | 53 + 53 rows |
| Month with no invoices (billing outage) | Left as is in clean; DQ detects it on its own; `fact_billing` estimates it as the mean of the customer's previous and next invoice (`IMPUTED_MISSING_INVOICE`) | 2024-08: 4,573 customer-months |
| Excel: non-standard header, 2 month formats, churn in % | Columns detected by name pattern (`th%ng%`, `%churn%`, `%mrr%`); parses both Excel dates and `Tmm/yyyy`; divides by 100 when the header contains `%` | 24 months |
| Blank TotalCharges (present in the base data) | Kept as NULL, only valid when tenure = 0 | 11 rows |

There are also defensive checks that currently catch nothing: contradicting churn flag / status / end date,
service values outside the catalogue, invoices outside the contract lifetime, tickets outside the lifetime,
exchange rates outside 10,000-50,000.

## 3. Data quality checks

`dbo.usp_run_dq_checks` runs at the end of every batch and writes to `mart.dq_check_results` (source of the Data Quality page).
Latest batch: **24 PASS, 2 WARN, 0 FAIL**.

| Group | Content |
|---|---|
| 1. Row reconciliation | 8 tables: `stg = clean + rejected`, no row lost |
| 2. Errors before/after | Duplicate keys, Yes/No variants, whitespace, non-ISO dates, negative/NULL amounts, blank TotalCharges |
| 3. CRM - Billing reconciliation | Orphan invoices (53 -> 0), tenure matches the number of billing periods, invoices outside the contract, **customer-months without an invoice -> WARN 2024-08: missing 4,573/4,573**, 7 customers whose only periods fall in the outage month (WARN) |
| 4. Amount totals | stg 14,851,431.41 -> clean 14,874,228.33 USD (+15,775.50 sign fixes, +9,997.42 recovered NULLs, -2,976.00 rejected), reconciled to 0.01. clean -> mart +292,814.93 of estimates |
| 5. Reference data | FX rate for every billed month; all 24 target months present |

## 4. Star schema (`mart`)

```mermaid
erDiagram
    dim_date ||--o{ fact_billing : "date_key (first of month)"
    dim_customer ||--o{ fact_billing : customer_key
    dim_contract ||--o{ fact_billing : contract_key
    dim_service ||--o{ fact_billing : service_key
    dim_payment_method ||--o{ fact_billing : payment_method_key
    dim_date ||--o{ fact_tickets : created_date_key
    dim_date |o--o{ fact_tickets : "resolved_date_key (inactive)"
    dim_customer ||--o{ fact_tickets : customer_key
    dim_contract ||--o{ fact_tickets : contract_key
    dim_service ||--o{ fact_tickets : service_key
    dim_payment_method ||--o{ fact_tickets : payment_method_key
    dim_date ||--o| fact_target : date_key

    dim_date {
        int date_key PK "yyyymmdd"
        date date UK
        smallint year
        tinyint quarter
        tinyint month
        char year_month
        int month_index
        bit is_analysis_window
    }
    dim_customer {
        int customer_key PK
        nvarchar customer_id UK
        nvarchar gender
        date signup_month "cohort"
        nvarchar tenure_group
        nvarchar customer_status
        date churn_month
    }
    dim_contract {
        int contract_key PK
        nvarchar contract_type
        nvarchar paperless_billing
        tinyint contract_term_months
    }
    dim_service {
        int service_key PK
        nvarchar internet_service
        nvarchar tech_support
        tinyint addon_count
    }
    dim_payment_method {
        int payment_method_key PK
        nvarchar payment_method UK
        nvarchar payment_type
    }
    fact_billing {
        int customer_key PK, FK
        int date_key PK, FK
        decimal amount_usd
        decimal amount_vnd
        bit is_churn_month
        bit is_imputed
        bit is_late
    }
    fact_tickets {
        nvarchar ticket_id PK
        int customer_key FK
        int created_date_key FK
        nvarchar category
        decimal resolution_hours
        bit is_within_90d_before_churn
    }
    fact_target {
        int date_key PK, FK
        decimal churn_rate_target
        decimal mrr_target_usd
    }
```

| Table | Grain | Key | Rows | Note |
|---|---|---|---:|---|
| `dim_date` | 1 day | `date_key` (yyyymmdd) | 2,922 | 2018-01-01..2025-12-31, continuous, used as the Date table. Monthly facts point at the first day of the month |
| `dim_customer` | 1 customer | `customer_key` (surrogate), `customer_id` (natural) | 7,043 | SCD1; includes cohort `signup_month`, `tenure_group`, `customer_status` |
| `dim_contract` | 1 contract type x paperless combination | `contract_key` | 6 | |
| `dim_payment_method` | 1 method | `payment_method_key` | 4 | `payment_type` Automatic/Manual |
| `dim_service` | 1 service combination (junk dimension) | `service_key` | 322 | Groups 9 service columns, adds `addon_count` |
| `fact_billing` | 1 customer x 1 billed month | (`customer_key`, `date_key`) | 227,990 | Month calendar comes from the CRM contract (not from invoices) so the billing outage month does not "lose" customers. Has `amount_usd`, `amount_vnd`, `is_churn_month`, `is_imputed`, payment status |
| `fact_tickets` | 1 ticket | `ticket_id` | 10,689 | Has `is_within_90d_before_churn` |
| `fact_target` | 1 month | `date_key` | 24 | Churn rate as a ratio (0.0139) |
| `customer_snapshot` | 1 billed customer | `customer_key` | 7,032 | Current profile + aggregated behaviour (materialised `v_customer_profile`), loaded at the end of every batch for the Explore page |
| `customer_factor` | 1 customer x 1 factor | (`customer_key`, `factor_key`) | 91,416 | Bridge table for dynamic filtering: the customer's value for each of 13 factors; `dim_factor` holds display names |

The fact tables and `customer_factor` also have a nonclustered columnstore index so aggregate queries run in batch mode
(see [03_dashboard_spec.md](03_dashboard_spec.md), Performance).

Every relationship is one-to-many from dimension to fact. Foreign keys are declared in the database, so orphan fact rows
are impossible. Because the service profile, contract and payment method do not change over time (a stage 1 assumption),
these keys are attached directly to the facts, so one slicer works for both `fact_billing` and `fact_tickets`.

**Reconciliation with the clean stage 1 data:** customer count, churners and churn rate per month in `fact_billing`
match exactly. MRR for 2024-08 (entirely estimated) = 292,814.93 USD vs the true 292,794.08 USD (0.007% off).
