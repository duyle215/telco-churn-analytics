/*
  Question 6: Which customer group is large, high-churn and a big share of MRR at the same time?
  Segment = contract type x internet type x payment type (Automatic/Manual), 18 segments in total.
  Source: mart.v_risk_segments. High-risk threshold: >= 5% of customers, churn >= 1.5x average, >= 10% of current MRR.

  Insight:
  - Only one segment meets all three: Month-to-month | Fiber optic | Manual
    (21.4% of window customers, churn 5.46%/month = 3.29x the 1.66% average, 17.0% of current MRR = 53,883 USD).
  - Its expected MRR loss is 2,941 USD/month, 48.9% of the company's total expected MRR loss
    (6,011 USD/month). The top three Month-to-month segments account for 80.4%.
  - Same Month-to-month | Fiber but paying automatically churns only 2.78%/month, about half:
    moving customers to automatic payment is a cheap lever, to be A/B tested before claiming causation.
  - Customers to contact: the last query (drill-through), ordered by current charge and ticket count.
*/
SELECT risk_segment, customers, churners, active_customers, current_mrr_usd,
       monthly_churn_rate, churn_lift, customer_share, mrr_share, expected_mrr_loss_usd, is_high_risk
FROM mart.v_risk_segments
ORDER BY expected_mrr_loss_usd DESC;

SELECT SUM(expected_mrr_loss_usd) AS total_expected_mrr_loss_usd,
       SUM(CASE WHEN is_high_risk = 1 THEN expected_mrr_loss_usd ELSE 0 END) AS high_risk_loss_usd,
       CAST(SUM(CASE WHEN is_high_risk = 1 THEN expected_mrr_loss_usd ELSE 0 END)
            / SUM(expected_mrr_loss_usd) AS DECIMAL(6,4)) AS high_risk_share
FROM mart.v_risk_segments;

-- Drill-through: active customers in the high-risk segment.
SELECT p.customer_id, p.tenure_months, p.current_mrr_usd, p.tickets, p.billing_tickets,
       p.late_payment_rate, p.tech_support, p.addon_count, p.payment_method
FROM mart.v_customer_profile p
JOIN mart.v_risk_segments r ON r.risk_segment = p.risk_segment AND r.is_high_risk = 1
WHERE p.customer_status = N'Active'
ORDER BY p.current_mrr_usd DESC, p.tickets DESC;
