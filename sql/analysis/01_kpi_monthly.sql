/*
  Question 1: Monthly KPIs (customers, churn rate, MRR, MRR lost to churn, ARPU) against target.
  Source: mart.v_kpi_monthly (metric definitions at the top of sql/views/mart_views.sql).

  Insight (latest ETL batch, window 2024-01..2025-12):
  - Billed customers grew 4,284 -> 5,240 (+22%), MRR grew 283,226 -> 322,470 USD (+13.9%).
  - Average churn 1.66%/month, above target in 9/12 months of 2024 (target 1.39%)
    and 10/12 months of 2025 (target 1.28%). Note: the targets were simulated at 90% of actual 2024 churn
    (src/generate/targets.py), so missing them is expected here; the query shows how target tracking works.
  - 2025-03 MRR +8.0% month over month (15% Fiber price increase), putting MRR 6.6% above target.
    MRR lost to churn then peaked at 12,018 USD in 2025-04 (~2.4x the usual ~5,000) and MRR fell four months
    in a row (2025-04..07). The simulation only moves WHEN Fiber churners leave, not how many, so this data
    cannot measure how much extra churn the price increase caused; that needs a control group.
  - MRR missed target only in 2024-11..2025-02 (-0.06% to -0.84%); all other months were above.
  - ARPU drifted down 66.11 -> 61.54 USD (apart from the price-increase jump); split by tenure/plan
    before drawing a conclusion.
  - Note: 2025-12 has 248 new customers (twice the usual) because the source data has many tenure = 1 customers;
    do not read it as a growth spike. MRR for 2024-08 is estimated (billing outage).
*/
SELECT year_month, customers, new_customers, churners,
       churn_rate, churn_rate_target, churn_vs_target,
       mrr_usd, mrr_target_usd, mrr_vs_target_pct, mrr_mom_pct,
       mrr_lost_usd, arpu_usd, imputed_rows
FROM mart.v_kpi_monthly
WHERE is_analysis_window = 1
ORDER BY date_key;

-- Yearly roll-up: months that missed target.
SELECT [year],
       AVG(churn_rate) AS avg_churn_rate,
       MAX(churn_rate_target) AS churn_target,
       SUM(CASE WHEN churn_rate > churn_rate_target THEN 1 ELSE 0 END) AS months_churn_above_target,
       SUM(CASE WHEN mrr_usd < mrr_target_usd THEN 1 ELSE 0 END) AS months_mrr_below_target,
       SUM(mrr_lost_usd) AS mrr_lost_usd
FROM mart.v_kpi_monthly
WHERE is_analysis_window = 1
GROUP BY [year]
ORDER BY [year];
