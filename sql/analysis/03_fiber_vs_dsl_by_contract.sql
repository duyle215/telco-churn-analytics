/*
  Question 3: Does Fiber really churn more than DSL, or only because Fiber customers are more often Month-to-month?
  Compare Fiber and DSL WITHIN the same contract type (controls for contract).
  Source: mart.v_churn_internet_by_contract.

  Insight:
  - Fiber customers are indeed more often Month-to-month (68.7% vs 50.6% for DSL),
    so part of the raw gap (41.9% vs 19.0%) comes from contract mix.
  - But within the same contract type, Fiber still churns clearly more:
      Month-to-month 54.6% vs 32.2% (1.7x); One year 19.3% vs 9.3% (2.1x); Two year 7.2% vs 1.9% (3.7x).
    => The Fiber effect exists independently of contract type.
  - Fiber costs 34-37 USD/month more than DSL within the same contract type, so price is the leading hypothesis
    to test (exit-reason survey, competitor price check).
*/
SELECT contract_type, internet_service, customers, churners, churn_rate, avg_monthly_charge_usd
FROM mart.v_churn_internet_by_contract
WHERE internet_service IN (N'Fiber optic', N'DSL')
ORDER BY contract_sort, internet_service;

-- Fiber - DSL gap within each contract type.
SELECT f.contract_type,
       f.churn_rate AS fiber_churn_rate,
       d.churn_rate AS dsl_churn_rate,
       f.churn_rate - d.churn_rate AS diff_pp,
       CAST(f.churn_rate / NULLIF(d.churn_rate, 0) AS DECIMAL(6,2)) AS ratio,
       f.avg_monthly_charge_usd - d.avg_monthly_charge_usd AS price_gap_usd
FROM mart.v_churn_internet_by_contract f
JOIN mart.v_churn_internet_by_contract d ON d.contract_type = f.contract_type AND d.internet_service = N'DSL'
WHERE f.internet_service = N'Fiber optic'
ORDER BY f.contract_sort;

-- Contract mix within each internet type (explains the part of the gap caused by mix).
SELECT internet_service, contract_type, customers,
       CAST(1.0 * customers / SUM(customers) OVER (PARTITION BY internet_service) AS DECIMAL(6,4)) AS share_in_internet_type
FROM mart.v_churn_internet_by_contract
ORDER BY internet_service, contract_sort;
