# Stage 1: Generating the source data

Base data: IBM Telco Customer Churn (Kaggle), 7,043 customers, 21 columns, a snapshot at a single point in time.
Everything else in the project (timeline, invoices, payments, tickets, targets) is **SYNTHETIC**,
derived from the base data by `python -m src.generate_sources` with `RANDOM_SEED = 42`.
No customer is duplicated or upsampled: the 7,043 original customers stay 7,043 customers
(the 45 duplicate CRM rows are a deliberately injected error, see section 4).

All parameters live in [src/config.py](../src/config.py).

## 1. Timeline reconstruction assumptions

| Assumption | Detail |
|---|---|
| Snapshot date | 2025-12-31 |
| Exit month of churners | Spread at random over 2024-01..2025-12, with mild seasonality (amplitude ±12%, peak in January) |
| Signup month | `signup_month = anchor_month - tenure`, where anchor = exit month (churners) or 2025-12 (active customers) |
| Billing periods | From `signup_month + 1` to `anchor_month`, so each customer has exactly `tenure` invoices and the churn month is the month of the last invoice |
| Customers with tenure = 0 | Signed up in 12/2025, no invoice yet (matches the 11 blank TotalCharges values in the base data) |
| Customer profile | Plan, contract type and payment method do not change over the lifetime |
| Price | MonthlyCharges is the price in the last billed month; each invoice varies ±2% (standard deviation) around it |
| Planted event | From 2025-03 the Fiber optic price rises 15%. Fiber invoices before 03/2025 = MonthlyCharges / 1.15 (for customers still active after it). Fiber churners are 1.6 / 2.6 / 1.9 times more likely to leave in 03, 04, 05/2025 |
| Payments | 15-day terms. Base late probability: Electronic check 12%, Mailed check 10%, automatic 3%. Churners x2, and x4 in their last 3 months. 25% of churners skip their final invoice |
| Tickets | The ticket system only has data from 2023-01. Poisson intensity per customer per month rises without TechSupport (x2.2), with Fiber (x1.4), for churners (x1.5, a further x3 in the last 3 months). Extra billing-complaint tickets for every Fiber customer in 03-05/2025 |
| Finance targets | 2024 churn = 90% of the actual 2024 average; 2025 a further 8% lower. MRR = actual MRR of the previous December x (1 + 0.6%/0.5%)^k |

**What this means for the analysis:**

- Before 2024-01 no customer churns (the base data only keeps customers who stayed until the 24-month window).
  Churn rate and related KPIs are therefore only meaningful in **2024-01..2025-12**. The steady growth in customers
  before 2024 is survivorship bias, not real growth.
- The price event, its timing, the ticket spike, late payments before churn and the target miss are all **planted**.
  The analysis uses them to check that its methods recover a known signal, and does not report them as business findings.
- The price event only changes **when** Fiber churners leave, not **how many**: the total number of Fiber churners comes
  from the base data. A spike in 03-05/2025 is balanced by fewer Fiber churners in other months, so this data cannot
  measure the net churn cost of the price increase.
- Billing-complaint tickets during the event are drawn for every Fiber customer, independent of who churns, so they do
  not predict churn at customer level.

## 2. Source systems

| Source | Object | Rows | Design note |
|---|---|---:|---|
| CRM (`src_crm`) | `customers` | 7,088 | No primary key, so customers can be duplicated |
| | `contracts` | 7,043 | Dates and Yes/No flags stored as NVARCHAR; `end_date` only for customers who left |
| | `services` | 7,043 | 1 row per customer, wide like the base table |
| Billing (`src_billing`) | `invoices` | 223,470 | No foreign key to CRM (separate systems) |
| | `payments` | 217,709 | Amounts are always correct, so they can recover NULL invoice amounts |
| Finance | `data/source/targets.xlsx` | 2 sheets x 12 months | Typed by hand, in Vietnamese |
| Ticket system | `data/source/support_tickets.csv` | 10,689 | 2023-01..2025-12 |
| FX rate API | [src/fx/client.py](../src/fx/client.py) | Months with invoices | See section 3 |

Source DDL: [sql/ddl/source/](../sql/ddl/source/).

## 3. USD to VND exchange rate (API)

- From 2024-03 onwards: [fawazahmed0/exchange-api](https://github.com/fawazahmed0/exchange-api), the rate of the
  first day with data in the month (22 months). This API has no history before 2024-03-02.
- Before 2024-03: World Bank, indicator `PA.NUS.FCRF` (official rate, **annual average**), 70 months.
  Every month of a year gets the same value.
- No mocks or made-up fallback: if an API fails, the load step writes `FAILED` to `etl_log` and the pipeline
  stops, so every rate in the warehouse can be traced to a public API.
- Each record keeps `provider` and `granularity`, so reports can state where a rate came from.

## 4. Injected data errors

The full list is generated on every run: `data/source/injected_errors.csv`. The table below is from the run with seed 42.

| # | Object | Column | Error type | Rows | Description |
|---:|---|---|---|---:|---|
| 1 | contracts | total_charges | blank_value_inherited | 11 | Present in the base data |
| 2 | customers | senior_citizen | inconsistent_boolean_inherited | 7,043 | Present in the base data: 0/1 while other flags use Yes/No |
| 3 | customers | customer_id | duplicate_key_exact | 20 | Exact duplicate |
| 4 | customers | customer_id | duplicate_key_conflicting | 25 | Different `dependents`, newer `updated_at`; 10 rows have a trailing space in the ID |
| 5 | customers | partner | inconsistent_boolean | 425 | Y/yes/1/YES, N/no/0/NO |
| 6 | customers | dependents | inconsistent_boolean | 425 | same |
| 7 | customers | gender | extra_whitespace | 80 | |
| 8 | contracts | paperless_billing | inconsistent_boolean | 352 | |
| 9 | contracts | churn_flag | inconsistent_boolean | 281 | |
| 10 | contracts | contract_type | extra_whitespace | 120 | |
| 11 | contracts | payment_method | extra_whitespace | 150 | |
| 12 | contracts | start_date | mixed_date_format | 2,133 | Mix of `yyyy-mm-dd`, `dd/mm/yyyy`, `yyyymmdd`, `dd-Mon-yyyy` |
| 13 | contracts | end_date | mixed_date_format | 535 | same |
| 14 | services | phone_service | inconsistent_boolean | 211 | |
| 15 | services | customer_id | extra_whitespace | 60 | |
| 16 | invoices | billing_month | missing_period | 4,573 | Billing outage: no invoices for 2024-08 |
| 17 | payments | invoice_id | missing_period | 4,552 | The matching payments are missing too |
| 18 | invoices | customer_id | orphan_key | 53 | 8 customer_id values not in CRM |
| 19 | payments | customer_id | orphan_key | 53 | Payments of the orphan invoices |
| 20 | invoices | amount_usd | negative_amount | 120 | Sign flipped |
| 21 | invoices | amount_usd | null_amount | 150 | Payments still hold the correct amount |
| 22 | invoices | customer_id | extra_whitespace | 400 | |
| 23 | support_tickets.csv | customer_id | extra_whitespace | 90 | |
| 24 | support_tickets.csv | created_at | mixed_date_format | 2,344 | Mix of `yyyy-mm-dd HH:MM:SS`, `dd/mm/yyyy HH:MM`, `dd-Mon-yyyy hh:mm AM/PM` |
| 25 | support_tickets.csv | resolved_at | mixed_date_format | 2,288 | same |
| 26 | targets.xlsx | (header) | non_standard_header | 2 sheets | Header on row 4; column names with diacritics, extra spaces and units, different between the 2 sheets |
| 27 | targets.xlsx | Tháng / Thang | mixed_date_format | 12 | The 2024 sheet stores Excel dates; the 2025 sheet stores the text `Tmm/yyyy` |
| 28 | targets.xlsx | Churn Rate mục tiêu (%) | unit_inconsistency | 24 | 1.39 means 1.39% |

**Note for the cleaning step:** SQL Server ignores *trailing* spaces when comparing with `=` and in `GROUP BY`.
So `customer_id <> LTRIM(RTRIM(customer_id))` only catches 274 of the 400 bad rows in `invoices`.
Catching them all needs `DATALENGTH` or `LIKE '% '`.

## 5. Checks after generation (figures from real queries)

These confirm that the generator produced the intended signals. They describe the simulation, not the business.

| Check | Result |
|---|---|
| Churners per month (before error injection) | 54-94 in normal months; **120 / 149 / 103** in 03 / 04 / 05/2025 (Fiber only: 94 / 121 / 89) |
| Monthly churn rate | 1.11%-2.13% in normal months; **2.49% / 3.10% / 2.15%** in 03 / 04 / 05/2025 |
| MRR | 296,869 USD (02/2025) -> 320,666 USD (03/2025), +8% from the Fiber price increase |
| Late payment rate | Churners 22.1%, retained customers 6.0%; Electronic check 17.7%, automatic about 3.4% |
| Tickets per customer (2023-2025) | No TechSupport: 2.13 (retained) / 2.40 (churned); with TechSupport: 1.16 / 1.48 |
| Billing tickets per month | 84 / 73 in 01 / 02/2025; **233 / 185 / 141** in 03 / 04 / 05/2025; 88 in 06/2025 |
| Error log vs database | Match: 7,088 customer rows (7,043 unique after TRIM), 120 negative, 150 NULL, 53 orphan invoices for 8 IDs, no invoices for 2024-08 |
