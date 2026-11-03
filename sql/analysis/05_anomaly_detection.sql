/*
  Question 5: Which months have unusual churn or ticket volume (more than 2 standard deviations from the 24-month mean)?
  Source: mart.v_anomaly_monthly (all customers and each internet type; churn rate, all tickets, Billing tickets).

  This is a method check, not a business finding: the simulation planted a 15% Fiber price increase in 2025-03
  (src/config.py). The view is not told the month, so finding it shows the detection works.

  Insight:
  - It recovers the planted event:
      All-customer churn 2025-04 = 3.10% (upper bound 2.53%, z = 3.28); Fiber churn 2025-04 = 6.07% (bound 4.77%, z = 3.28).
      Tickets 2025-03 = 552 (mean 331, z = 3.54); Billing tickets 2025-03 = 285 vs mean 90 (z = 3.69).
  - Billing tickets peak one month before churn (2025-03 vs 2025-04). That lag was also set in the simulation, and the
    event tickets are drawn for every Fiber customer regardless of who churns, so it does not show that tickets predict churn.
  - Churn in 2025-03 (2.49%) and 2025-05 (2.15%) is also high but under the bound, because the peak month itself inflates
    the standard deviation (masking). For monitoring, compute the bound from earlier normal months
    (rolling baseline) instead of the whole series.
  - A few mild breaches (z 2.0-2.7) in small groups (DSL tickets 2025-08/11, no-internet customers) are noise:
    with 12 series x 24 months, some points above 2 sigma are expected. Require z > 3 or two months in a row.
*/
SELECT year_month, segment, metric, value, mean_value, upper_bound, z_score
FROM mart.v_anomaly_monthly
WHERE is_anomaly = 1
ORDER BY metric, segment, year_month;

-- Full Fiber churn and Billing ticket series, to see the shape of the event.
SELECT year_month, metric, value, upper_bound, z_score, is_anomaly
FROM mart.v_anomaly_monthly
WHERE (segment = N'Fiber optic' AND metric = N'Churn rate') OR (segment = N'All' AND metric = N'Billing tickets')
ORDER BY metric, year_month;
