/*
  Question 4: How long are customers retained, by start month (cohort)?
  Source: mart.v_cohort_retention. Only cohorts whose first bill is in 2024-01 or later (cohorts 2023-12..2025-11),
  because older cohorts only contain customers who survived until 2024 (survivorship bias).

  Insight (retention averaged across cohorts, weighted by cohort size):
  - Month 1: 86.1%; month 3: 78.2%; month 6: 71.2%; month 12: 61.1%; month 18: 55.0%.
    13.9 points are lost right after the first bill: onboarding is the biggest leak.
  - Cohorts 2025-01..2025-04 kept only 70.9-73.3% after 3 months vs 74-84% for the 2024 cohorts:
    their first three months overlap the simulated Fiber price increase.
  - Cohort 2024-04 has the lowest 12-month retention (49.2%); its 12th month falls on 2025-04.
*/
-- Retention matrix (cohort x months since first bill).
SELECT cohort_label, cohort_size, month_offset, active_customers, retention_rate
FROM mart.v_cohort_retention
ORDER BY cohort_month, month_offset;

-- Weighted average retention curve; each point only uses cohorts old enough to reach it.
SELECT month_offset,
       COUNT(*) AS cohorts,
       SUM(cohort_size) AS customers,
       CAST(1.0 * SUM(active_customers) / SUM(cohort_size) AS DECIMAL(6,4)) AS weighted_retention
FROM mart.v_cohort_retention
GROUP BY month_offset
ORDER BY month_offset;

-- Retention at months 3/6/12 for each cohort.
SELECT cohort_label, cohort_size,
       MAX(CASE WHEN month_offset = 3 THEN retention_rate END) AS retention_m3,
       MAX(CASE WHEN month_offset = 6 THEN retention_rate END) AS retention_m6,
       MAX(CASE WHEN month_offset = 12 THEN retention_rate END) AS retention_m12
FROM mart.v_cohort_retention
GROUP BY cohort_month, cohort_label, cohort_size
ORDER BY cohort_month;
