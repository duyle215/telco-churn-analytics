# Stage 5: Dashboard

A web dashboard instead of Power BI (Power BI Desktop is not installed on the development machine). It reads the
star schema in `TelcoDW.mart` and computes no metrics itself: every calculation lives in SQL.

**Run:** `python -m src.dashboard.app`, then open <http://127.0.0.1:5000>.

## 1. Three pages

| Page | Audience | Layout |
|---|---|---|
| **Churn explorer** | Management, Marketing, Customer care | Fits one screen (reference frame: one landscape A4 page) |
| **What-if Scenario** | Management, Marketing | Fits one screen |
| **Data Quality** | Data team, anyone looking things up | Reference page, may be long; the top still summarises |

Three earlier static report pages (Overview, Drivers, Risk) were merged into the explorer: each static page was only
a fixed filter combination, and is now a "saved view" or a single click.

**Layout rule for the two main pages:** one summary sentence, a KPI row, a few charts. Details only open on demand
(popover, drawer); the viewer never has to scroll. Checked with a 1440x900 screenshot: page height equals window height.

## 2. Churn explorer

A Power BI-style report page: a grid of small charts, little text, one screen (16:9 / landscape A4 frame).

```
┌ View ▾ │ Contract ▾ │ Internet ▾ │ Tenure ▾ │ Add-ons ▾ │ Payment ▾ │ Tech support ▾ │ More ▾ │   Clear filters ┐
│ 1 generated summary line                                                                                   │
├ KPI+sparkline: Customers │ Churn rate (monthly) │ MRR │ MRR lost to churn │ ARPU                           ┤
├ Monthly churn rate (line)          │ Monthly MRR (bars)             │ Factors that matter most            ┤
├ Churn by contract │ Retention curve │ Donut: where churners come from │ (Filtering ✕ · ▲/▼ tiles · scroll)┘
```

- **Filtering:** a one-row filter bar without a scrollbar (6 main factors + "More"). Several values of one factor are OR, different factors are AND. The picker shows each option's customer count and churn rate. Filters are kept in the URL.
- **Two kinds of question:** the bar chart answers *which group churns at a high rate*; the donut answers *where churned customers come from* (mix). Example: Fiber churns 41.9% but makes up 69% of all churners, because it both churns more and is large.
- **When do customers leave:** a cohort retention curve, not churn by tenure band. A churner's tenure stops at the exit month while active customers keep ageing, so churn by tenure band is biased towards short tenure. The curve only uses customers whose first bill is in the analysis window and, at each month, only customers who could be observed that long.
- **Power BI-style cross-filtering:** click a bar (contract) or a donut slice (internet) to filter on that value, click again to remove it. The selected bar stays solid, the others fade; the dashed line is the company-wide churn rate.
- **Remove filters anywhere:** ✕ on the filter bar, untick in the picker, click the solid bar again, or ✕ in the "Filtering" row of the panel.
- **Five KPI cards, one template** (Customers, Churn rate (monthly), MRR, MRR lost to churn, ARPU): the value is the latest month; the badge is the change vs the previous month, coloured by meaning (customers/MRR/ARPU up is good, churn rate/MRR lost up is bad); the sparkline shows 24 months of the same metric; the footer compares with the whole company when filtered, or with the target/average otherwise.
- **Factors that matter most:** every factor ranked from strongest to weakest, scrolling inside the panel. Each factor has a ▲ tile for the option that churns most and a ▼ tile for the least, click to filter. Options under 30 customers are not ranked (for a tiny group the bar drops to 5 with a "Small sample" label); "No internet service" is skipped under internet-dependent factors. Tenure is a filter but is not ranked, for the reason above.
- **Customer list and CSV reuse the page filters:** "View & download CSV" opens a preview (active customers matching the page filters). It can be narrowed with quick filters (top 25% charge, has billing complaints, often late ≥ 20%, no tech support, first-year customers), searched, sorted and paged; "Download CSV" exports exactly the matching rows. Filtering, quick filters, sorting, paging (`OFFSET/FETCH`) and CSV generation all run on the server (`mart.usp_explore_customers`); the browser only sends parameters via AJAX and receives one page of 50 rows. "See every option of every factor" at the bottom of the panel opens all 13 factors.

## 3. Each chart answers one question

Each chart has the **business question** on line 1 and the **answer** computed from the filtered data on line 2 (it changes with the filters).

| # | Question | Metric | Source (result set of `mart.usp_explore`) | Chart | Generated answer |
|---|---|---|---|---|---|
| 1 | Is the churn rate rising or falling? | churners / customers in the month | 3 · monthly trend | Line, vs company or target | Peak, latest month vs average |
| 2 | Is recurring revenue on target? (filtered: how much does this group bring?) | total monthly charges, Finance target | 3 · monthly trend | Bars + target line | Months on target; gap in the latest month (or MRR share) |
| 3 | Which contract type churns most? | 24-month churn share by contract | 2 · per-factor stats | Horizontal bars, cross-filter | How many times the highest option is the lowest |
| 4 | When do new customers leave? | share still billed k months after the first bill | 5 · retention + 6 · retention denominator | Line, vs company when filtered | Share gone after the first bill, share still active after 12 months |
| 5 | Where do churned customers come from? | share of churners by internet type | 2 · per-factor stats | Donut, cross-filter | Largest share in % |
| 6 | Which factor makes the biggest difference? | churn gap between the highest and lowest option, 12 ranked factors | 2 · per-factor stats | Ranked list | Top factor and its two options |
| KPI | How big is the group, how much does it churn, how much money is lost? | customers, churn rate, MRR, expected MRR loss | 1 · KPI + 3 · trend | Number cards + sparklines | Vs previous month / overall |

**How the queries are organised:** grouped by the **grain** of the data, not by chart.
Questions 1, 2 and the KPI sparklines all need monthly figures, so they share one result set. Questions 3, 5 and 6 all need
"the churn rate of each option in the filtered context", so they share one result set (one scan of the bridge table).
Writing one query per chart would mean 6-8 calls (N+1) and scanning the fact table several times for the same result.

**Division of work:** metric definitions (numerator, denominator, time window) live in SQL, the single source of truth.
The UI only picks which numbers to mention (largest, smallest, latest month) and phrases them as a sentence.

## 4. Query performance

Each filter change calls **1 stored procedure, 1 round trip** (`mart.usp_explore`), with no N+1:

| Technique | Why |
|---|---|
| Static stored procedure, filters passed as JSON (`OPENJSON`) | The plan is compiled once and reused; no dynamic SQL, so no path for SQL injection |
| One call returns several result sets (KPIs, per-factor impact, trend...) | One round trip instead of many |
| Selected group and whole company computed in the same scan (`SUM(CASE WHEN sel = 1 ...)`) | No second query for "whole company" |
| Bridge table `mart.customer_factor` (customer x factor x value) | Any filter is a single join with the filter table; the impact of 13 factors is one grouping instead of 13 queries |
| `mart.customer_snapshot` (materialised customer profile view) | The view aggregates 228 thousand fact rows on every read (~2-3 s); the snapshot table loads once per ETL batch |
| Columnstore index on `fact_billing`, `fact_tickets`, `customer_factor` | Batch mode: the impact step dropped from 260 ms to 35 ms |
| Server-side paging of the customer list (`OFFSET/FETCH`), sorting with `CASE` over an allow-list of columns, server-built CSV | Only 50 rows per call instead of the whole group (up to ~5,200 rows, 1.4 MB); no dynamic SQL |
| Server-side cache per ETL batch + filters | A filter seen before returns immediately (~2 ms); re-running the ETL refreshes the cache |
| Merging quick successive clicks (120 ms) and cancelling stale requests (`AbortController`) | Clicking several options quickly does not fire a burst of requests |

Measured on the development machine: ~600 ms with the initial dynamic SQL, **~290 ms** after optimisation (first time a
filter is used), **~2 ms** on a cache hit. Per-statement timings from `sys.dm_exec_query_stats`.

**Correctness check:** the filter "month-to-month + Fiber + manual payment" gives 1,508 customers, churn 5.46%/month,
MRR $53,883, expected MRR loss $2,941, matching the risk segment in
[06_risk_segments.sql](../sql/analysis/06_risk_segments.sql). Without filters the monthly figures match
`mart.v_kpi_monthly` (e.g. 2025-04: 4,814 customers, 149 churners).

## 5. Presentation rules

- Plain-language labels for non-specialists ("Month-to-month", "Manual payment", "Churned within the 24-month window"), and every rate says its unit (per month or within the window).
- Colour: blue is the selected group, grey the whole company, dashed lines are targets. Green/red only mark the options that churn least/most, always with a number next to them.
- No dual-axis charts; every chart has a tooltip; light and dark themes have their own palettes; below 900 px the layout becomes a single column.
