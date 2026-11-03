/*
  Question 7: Baseline numbers for the what-if, and the estimate: if X% of active Month-to-month customers move to
  a one-year contract, how much MRR is kept?
  Source: mart.v_whatif_contract_base.

  Model assumptions:
  - Moved customers take on the One year monthly churn rate and keep the Month-to-month ARPU
    (before any discount used to convince them).
  - Monthly churn is constant; customers left after k months = N x (1 - churn)^k.
  - This is a correlational gap between two groups, not a causal effect: customers who switch voluntarily may already
    be lower risk, so the result is an upper bound. It needs a test with a control group.

  Insight:
  - Month-to-month: 2,220 active customers, MRR 136,455 USD, churn 3.79%/month, 7x One year (0.54%)
    and 30x Two year (0.12%). The group loses on average 69 customers and 5,035 USD MRR per month, 86.8%
    of the company's MRR lost to churn (5,798 USD/month).
  - Moving 20% (444 customers) to One year: ~14 fewer churners in the first month; 137 more customers after 12 months,
    month-12 MRR higher by 8,404 USD (2.6% of current MRR); 59,162 USD of revenue kept over 12 months.
    10% scenario: 29,581 USD; 30%: 88,744 USD (linear in the conversion rate).
  - The largest discount that still breaks even over 12 months is ~18.7% of the price (independent of the conversion rate).
    A 10-15% one-year offer is a safe range to test.
*/
SELECT contract_type, active_customers, current_mrr_usd, arpu_usd,
       churners_in_window, monthly_churn_rate, avg_churners_per_month, avg_mrr_lost_per_month_usd
FROM mart.v_whatif_contract_base
ORDER BY contract_sort;

-- Scenarios: move 10% / 20% / 30% of Month-to-month customers to One year, 12-month horizon.
WITH base AS (
    SELECT MAX(CASE WHEN contract_type = N'Month-to-month' THEN active_customers END) AS m2m_customers,
           MAX(CASE WHEN contract_type = N'Month-to-month' THEN arpu_usd END) AS m2m_arpu,
           MAX(CASE WHEN contract_type = N'Month-to-month' THEN CAST(monthly_churn_rate AS FLOAT) END) AS churn_m2m,
           MAX(CASE WHEN contract_type = N'One year' THEN CAST(monthly_churn_rate AS FLOAT) END) AS churn_1y
    FROM mart.v_whatif_contract_base
), scenario AS (
    SELECT v.shift_pct, b.*, ROUND(b.m2m_customers * v.shift_pct, 0) AS moved_customers
    FROM base b CROSS JOIN (VALUES (0.10), (0.20), (0.30)) v(shift_pct)
), months AS (
    SELECT TOP (12) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS k FROM sys.all_objects
)
SELECT s.shift_pct,
       s.moved_customers,
       CAST(s.moved_customers * s.m2m_arpu AS DECIMAL(12,2)) AS moved_mrr_usd,
       CAST(s.moved_customers * (s.churn_m2m - s.churn_1y) AS DECIMAL(10,2)) AS churners_avoided_month1,
       CAST(s.moved_customers * (POWER(1 - s.churn_1y, 12) - POWER(1 - s.churn_m2m, 12)) AS DECIMAL(10,1)) AS extra_customers_after_12m,
       CAST(s.moved_customers * s.m2m_arpu * (POWER(1 - s.churn_1y, 12) - POWER(1 - s.churn_m2m, 12)) AS DECIMAL(12,2)) AS mrr_retained_month12_usd,
       CAST(SUM(s.moved_customers * s.m2m_arpu * (POWER(1 - s.churn_1y, m.k) - POWER(1 - s.churn_m2m, m.k))) AS DECIMAL(12,2)) AS revenue_retained_12m_usd,
       -- Largest discount for moved customers that still breaks even over 12 months:
       -- revenue kept / revenue of the moved group if they churn at the One year rate.
       CAST(SUM(POWER(1 - s.churn_1y, m.k) - POWER(1 - s.churn_m2m, m.k)) / SUM(POWER(1 - s.churn_1y, m.k)) AS DECIMAL(6,4)) AS break_even_discount_pct
FROM scenario s CROSS JOIN months m
GROUP BY s.shift_pct, s.moved_customers, s.m2m_arpu, s.churn_m2m, s.churn_1y
ORDER BY s.shift_pct;
