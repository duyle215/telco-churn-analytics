/*
  Question 2: Churn rate by driver (contract, tenure, internet, add-on services, payment...), with customer counts.
  Source: mart.v_churn_drivers. Unit: customers billed in the 24-month window (7,032 customers, 1,869 churned,
  26.6% churned within the window). lift_vs_overall = group churn / overall churn.

  Insight:
  - Contract is the strongest driver: Month-to-month 42.7% vs One year 11.3% and Two year 2.9% (~15x gap).
  - Tenure: 0-12 months 47.7%, falling to 6.6% at 61-72 months. Treat with care: a churner's tenure stops at
    the exit month while active customers keep ageing, so short-tenure groups look worse by construction.
    Use the cohort retention in 04_cohort_retention.sql to answer "when do customers leave".
  - Add-on services show a clean monotonic pattern: 0 add-ons 52.2% -> 6 add-ons 5.3%.
    No Tech support 41.7% vs 15.2% with it; no Online security 41.8% vs 14.6%.
  - Fiber optic 41.9% vs DSL 19.0%; Electronic check 45.3% vs 15-19% for the other methods.
  - Senior citizen 41.7% vs 23.7%; Paperless billing 33.6% vs 16.4%.
  - Drivers are correlated (Fiber / Electronic check customers tend to be Month-to-month), so they do not add up;
    question 3 separates internet type from contract type.
*/
SELECT driver, driver_value, customers, churners, churn_rate, lift_vs_overall
FROM mart.v_churn_drivers
ORDER BY driver, COALESCE(sort_order, 99), churn_rate DESC;

-- Gap between the highest- and lowest-churn group of each driver: which driver separates customers best.
SELECT driver,
       MAX(churn_rate) AS max_churn_rate,
       MIN(churn_rate) AS min_churn_rate,
       MAX(churn_rate) - MIN(churn_rate) AS spread
FROM mart.v_churn_drivers
GROUP BY driver
ORDER BY spread DESC;
