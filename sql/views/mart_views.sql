/*
  View phân tích trong mart, dùng cho sql/analysis/ và Power BI.
  Quy ước chỉ số dùng xuyên suốt:
  - Khách trong tháng   = số dòng fact_billing của tháng (khách có tính cước tháng đó).
  - Churn rate tháng    = khách có is_churn_month = 1 / khách trong tháng.
  - MRR                 = tổng amount_usd trong tháng. ARPU = MRR / khách.
  - MRR mất do churn    = cước tháng cuối của khách rời đi trong tháng (doanh thu định kỳ sẽ mất từ tháng sau).
  - Churn rate theo tháng của một nhóm = khách rời đi / khách-tháng trong cửa sổ phân tích,
    để so sánh công bằng giữa các nhóm có thời gian quan sát khác nhau.
  Chỉ số churn chỉ có ý nghĩa trong cửa sổ phân tích 2024-01..2025-12 (dim_date.is_analysis_window).
*/

/* 1 dòng / khách có tính cước: hồ sơ hiện tại + hành vi. Dùng cho driver, phân khúc rủi ro và drill-through. */
CREATE OR ALTER VIEW mart.v_customer_profile AS
WITH ranked AS (
    SELECT f.customer_key, f.contract_key, f.service_key, f.payment_method_key, f.amount_usd,
           ROW_NUMBER() OVER (PARTITION BY f.customer_key ORDER BY f.date_key DESC) AS rn
    FROM mart.fact_billing f
), billing AS (
    SELECT f.customer_key,
           COUNT(*) AS billed_months,
           SUM(CASE WHEN d.is_analysis_window = 1 THEN 1 ELSE 0 END) AS window_months,
           SUM(f.amount_usd) AS lifetime_revenue_usd,
           AVG(CAST(f.is_late AS FLOAT)) AS late_payment_rate
    FROM mart.fact_billing f JOIN mart.dim_date d ON d.date_key = f.date_key
    GROUP BY f.customer_key
), tickets AS (
    SELECT customer_key, COUNT(*) AS tickets,
           SUM(CASE WHEN category = N'Billing' THEN 1 ELSE 0 END) AS billing_tickets,
           SUM(CASE WHEN category = N'Technical' THEN 1 ELSE 0 END) AS technical_tickets
    FROM mart.fact_tickets GROUP BY customer_key
)
SELECT c.customer_key, c.customer_id, c.gender, c.senior_citizen, c.partner, c.dependents,
       c.signup_month, c.tenure_months, c.tenure_group, c.tenure_group_order, c.customer_status, c.churn_month,
       CASE WHEN c.customer_status = N'Churned' THEN 1 ELSE 0 END AS is_churned,
       ct.contract_type, ct.contract_sort, ct.paperless_billing,
       s.internet_service, s.phone_service, s.tech_support, s.online_security, s.online_backup,
       s.device_protection, s.addon_count, s.has_streaming,
       pm.payment_method, pm.payment_type,
       CONCAT(ct.contract_type, N' | ', s.internet_service, N' | ', pm.payment_type) AS risk_segment,
       r.amount_usd AS last_billed_amount_usd,
       CASE WHEN c.customer_status = N'Active' THEN r.amount_usd END AS current_mrr_usd,
       b.billed_months, b.window_months, b.lifetime_revenue_usd,
       CAST(b.late_payment_rate AS DECIMAL(6,4)) AS late_payment_rate,
       ISNULL(t.tickets, 0) AS tickets, ISNULL(t.billing_tickets, 0) AS billing_tickets,
       ISNULL(t.technical_tickets, 0) AS technical_tickets,
       CASE WHEN b.window_months > 0 THEN 1 ELSE 0 END AS in_analysis_window
FROM mart.dim_customer c
JOIN ranked r ON r.customer_key = c.customer_key AND r.rn = 1
JOIN mart.dim_contract ct ON ct.contract_key = r.contract_key
JOIN mart.dim_service s ON s.service_key = r.service_key
JOIN mart.dim_payment_method pm ON pm.payment_method_key = r.payment_method_key
JOIN billing b ON b.customer_key = c.customer_key
LEFT JOIN tickets t ON t.customer_key = c.customer_key;
GO

/* KPI theo tháng so với chỉ tiêu. */
CREATE OR ALTER VIEW mart.v_kpi_monthly AS
WITH m AS (
    SELECT date_key,
           COUNT(*) AS customers,
           SUM(CAST(is_first_month AS INT)) AS new_customers,
           SUM(CAST(is_churn_month AS INT)) AS churners,
           SUM(amount_usd) AS mrr_usd,
           SUM(CASE WHEN is_churn_month = 1 THEN amount_usd ELSE 0 END) AS mrr_lost_usd,
           SUM(amount_vnd) AS mrr_vnd,
           SUM(CAST(is_imputed AS INT)) AS imputed_rows
    FROM mart.fact_billing GROUP BY date_key
)
SELECT d.date_key, d.year_month, d.[year], d.[month], d.is_analysis_window,
       m.customers, m.new_customers, m.churners,
       CAST(1.0 * m.churners / m.customers AS DECIMAL(9,6)) AS churn_rate,
       t.churn_rate_target,
       CAST(1.0 * m.churners / m.customers - t.churn_rate_target AS DECIMAL(9,6)) AS churn_vs_target,
       m.mrr_usd, t.mrr_target_usd,
       m.mrr_usd - t.mrr_target_usd AS mrr_vs_target_usd,
       CAST(m.mrr_usd / t.mrr_target_usd - 1 AS DECIMAL(9,4)) AS mrr_vs_target_pct,
       CAST(m.mrr_usd / LAG(m.mrr_usd) OVER (ORDER BY d.date_key) - 1 AS DECIMAL(9,4)) AS mrr_mom_pct,
       m.mrr_lost_usd,
       CAST(m.mrr_usd / m.customers AS DECIMAL(10,2)) AS arpu_usd,
       m.mrr_vnd, m.imputed_rows
FROM m
JOIN mart.dim_date d ON d.date_key = m.date_key
LEFT JOIN mart.fact_target t ON t.date_key = m.date_key;
GO

/* Churn rate theo từng driver, ở cấp khách (khách có tính cước trong cửa sổ phân tích). */
CREATE OR ALTER VIEW mart.v_churn_drivers AS
WITH p AS (SELECT * FROM mart.v_customer_profile WHERE in_analysis_window = 1),
drivers AS (
    SELECT N'Contract' AS driver, contract_type AS driver_value, contract_sort AS sort_order, is_churned FROM p
    UNION ALL SELECT N'Tenure group', tenure_group, tenure_group_order, is_churned FROM p
    UNION ALL SELECT N'Internet service', internet_service, CASE internet_service WHEN N'Fiber optic' THEN 1 WHEN N'DSL' THEN 2 ELSE 3 END, is_churned FROM p
    UNION ALL SELECT N'Tech support', tech_support, CASE tech_support WHEN N'No' THEN 1 WHEN N'Yes' THEN 2 ELSE 3 END, is_churned FROM p
    UNION ALL SELECT N'Online security', online_security, CASE online_security WHEN N'No' THEN 1 WHEN N'Yes' THEN 2 ELSE 3 END, is_churned FROM p
    UNION ALL SELECT N'Add-on services', CONCAT(addon_count, N' add-on'), addon_count, is_churned FROM p WHERE internet_service <> N'No'
    UNION ALL SELECT N'Payment method', payment_method, NULL, is_churned FROM p
    UNION ALL SELECT N'Paperless billing', paperless_billing, NULL, is_churned FROM p
    UNION ALL SELECT N'Senior citizen', senior_citizen, NULL, is_churned FROM p
)
SELECT driver, driver_value, sort_order,
       COUNT(*) AS customers,
       SUM(is_churned) AS churners,
       CAST(1.0 * SUM(is_churned) / COUNT(*) AS DECIMAL(6,4)) AS churn_rate,
       CAST(1.0 * SUM(is_churned) / COUNT(*) / (SELECT 1.0 * SUM(is_churned) / COUNT(*) FROM p) AS DECIMAL(6,2)) AS lift_vs_overall
FROM drivers
GROUP BY driver, driver_value, sort_order;
GO

/* Churn Fiber vs DSL trong cùng loại hợp đồng (phân tích có kiểm soát). */
CREATE OR ALTER VIEW mart.v_churn_internet_by_contract AS
SELECT contract_type, contract_sort, internet_service,
       COUNT(*) AS customers,
       SUM(is_churned) AS churners,
       CAST(1.0 * SUM(is_churned) / COUNT(*) AS DECIMAL(6,4)) AS churn_rate,
       CAST(AVG(last_billed_amount_usd) AS DECIMAL(10,2)) AS avg_monthly_charge_usd
FROM mart.v_customer_profile
WHERE in_analysis_window = 1
GROUP BY contract_type, contract_sort, internet_service;
GO

/*
  Cohort retention theo tháng ký hợp đồng. Chỉ lấy cohort có kỳ cước đầu tiên trong cửa sổ phân tích:
  cohort cũ hơn chỉ còn những khách sống sót tới 2024 nên retention sẽ bị thổi phồng.
  month_offset 0 = kỳ cước đầu tiên. Khách churn vẫn được tính trong tháng rời đi (tháng có hoá đơn cuối).
*/
CREATE OR ALTER VIEW mart.v_cohort_retention AS
WITH cohort AS (
    SELECT c.customer_key, c.signup_month, c.first_billing_month
    FROM mart.dim_customer c
    WHERE c.first_billing_month >= dbo.fn_config_date('analysis_window_start')
), activity AS (
    SELECT co.signup_month, DATEDIFF(MONTH, co.first_billing_month, d.[date]) AS month_offset, COUNT(*) AS active_customers
    FROM mart.fact_billing f
    JOIN cohort co ON co.customer_key = f.customer_key
    JOIN mart.dim_date d ON d.date_key = f.date_key
    GROUP BY co.signup_month, DATEDIFF(MONTH, co.first_billing_month, d.[date])
), size AS (
    SELECT signup_month, COUNT(*) AS cohort_size FROM cohort GROUP BY signup_month
)
SELECT a.signup_month AS cohort_month, CONVERT(CHAR(7), a.signup_month, 120) AS cohort_label,
       a.month_offset, s.cohort_size, a.active_customers,
       CAST(1.0 * a.active_customers / s.cohort_size AS DECIMAL(6,4)) AS retention_rate
FROM activity a JOIN size s ON s.signup_month = a.signup_month;
GO

/*
  Phát hiện bất thường: giá trị tháng lệch khỏi trung bình 24 tháng quá 2 độ lệch chuẩn.
  Xét churn rate và số ticket, cho toàn bộ khách và từng loại internet.
*/
CREATE OR ALTER VIEW mart.v_anomaly_monthly AS
WITH churn AS (
    SELECT d.date_key, d.year_month, N'All' AS segment,
           CAST(1.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*) AS FLOAT) AS value
    FROM mart.fact_billing f JOIN mart.dim_date d ON d.date_key = f.date_key
    WHERE d.is_analysis_window = 1
    GROUP BY d.date_key, d.year_month
    UNION ALL
    SELECT d.date_key, d.year_month, s.internet_service,
           CAST(1.0 * SUM(CAST(f.is_churn_month AS INT)) / COUNT(*) AS FLOAT)
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key
    JOIN mart.dim_service s ON s.service_key = f.service_key
    WHERE d.is_analysis_window = 1
    GROUP BY d.date_key, d.year_month, s.internet_service
), tickets AS (
    SELECT d.year_month, N'All' AS segment, t.category
    FROM mart.fact_tickets t JOIN mart.dim_date d ON d.date_key = t.created_date_key
    WHERE d.is_analysis_window = 1
    UNION ALL
    SELECT d.year_month, s.internet_service, t.category
    FROM mart.fact_tickets t
    JOIN mart.dim_date d ON d.date_key = t.created_date_key
    JOIN mart.dim_service s ON s.service_key = t.service_key
    WHERE d.is_analysis_window = 1
), series AS (
    SELECT year_month, segment, N'Churn rate' AS metric, value FROM churn
    UNION ALL
    SELECT year_month, segment, N'Tickets', COUNT(*) FROM tickets GROUP BY year_month, segment
    UNION ALL
    SELECT year_month, segment, N'Billing tickets', SUM(CASE WHEN category = N'Billing' THEN 1 ELSE 0 END)
    FROM tickets GROUP BY year_month, segment
), stats AS (
    SELECT s.*,
           AVG(value) OVER (PARTITION BY metric, segment) AS mean_value,
           STDEVP(value) OVER (PARTITION BY metric, segment) AS sd_value
    FROM series s
)
SELECT d.date_key, s.year_month, s.segment, s.metric,
       CAST(s.value AS DECIMAL(12,6)) AS value,
       CAST(s.mean_value AS DECIMAL(12,6)) AS mean_value,
       CAST(s.sd_value AS DECIMAL(12,6)) AS sd_value,
       CAST(s.mean_value + 2 * s.sd_value AS DECIMAL(12,6)) AS upper_bound,
       CAST(s.mean_value - 2 * s.sd_value AS DECIMAL(12,6)) AS lower_bound,
       CAST((s.value - s.mean_value) / NULLIF(s.sd_value, 0) AS DECIMAL(8,2)) AS z_score,
       CASE WHEN ABS(s.value - s.mean_value) > 2 * s.sd_value THEN 1 ELSE 0 END AS is_anomaly
FROM stats s
JOIN mart.dim_date d ON d.year_month = s.year_month AND d.is_month_start = 1;
GO

/*
  Phân khúc rủi ro = loại hợp đồng x loại internet x hình thức thanh toán.
  - monthly_churn_rate: khách rời đi / khách-tháng trong cửa sổ phân tích.
  - current_mrr_usd: MRR tháng snapshot của khách còn hoạt động.
  - expected_mrr_loss_usd: MRR dự kiến mất mỗi tháng nếu churn giữ nguyên = current_mrr x monthly_churn_rate.
  Ngưỡng "rủi ro cao" (đồng thời cả ba): >= 5% khách, churn >= 1,5 lần bình quân, >= 10% MRR.
*/
CREATE OR ALTER VIEW mart.v_risk_segments AS
WITH window_stats AS (
    SELECT ct.contract_type, ct.contract_sort, s.internet_service, pm.payment_type,
           COUNT(DISTINCT f.customer_key) AS customers,
           COUNT(*) AS customer_months,
           SUM(CAST(f.is_churn_month AS INT)) AS churners
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_analysis_window = 1
    JOIN mart.dim_contract ct ON ct.contract_key = f.contract_key
    JOIN mart.dim_service s ON s.service_key = f.service_key
    JOIN mart.dim_payment_method pm ON pm.payment_method_key = f.payment_method_key
    GROUP BY ct.contract_type, ct.contract_sort, s.internet_service, pm.payment_type
), now_stats AS (
    SELECT ct.contract_type, s.internet_service, pm.payment_type,
           COUNT(*) AS active_customers, SUM(f.amount_usd) AS current_mrr_usd
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_snapshot_month = 1
    JOIN mart.dim_contract ct ON ct.contract_key = f.contract_key
    JOIN mart.dim_service s ON s.service_key = f.service_key
    JOIN mart.dim_payment_method pm ON pm.payment_method_key = f.payment_method_key
    WHERE f.is_churn_month = 0
    GROUP BY ct.contract_type, s.internet_service, pm.payment_type
), combined AS (
    SELECT w.*, ISNULL(n.active_customers, 0) AS active_customers, ISNULL(n.current_mrr_usd, 0) AS current_mrr_usd,
           1.0 * w.churners / w.customer_months AS monthly_churn_rate,
           1.0 * SUM(w.churners) OVER () / SUM(w.customer_months) OVER () AS overall_monthly_churn_rate,
           1.0 * w.customers / SUM(w.customers) OVER () AS customer_share,
           ISNULL(n.current_mrr_usd, 0) / SUM(ISNULL(n.current_mrr_usd, 0)) OVER () AS mrr_share
    FROM window_stats w
    LEFT JOIN now_stats n ON n.contract_type = w.contract_type AND n.internet_service = w.internet_service
                         AND n.payment_type = w.payment_type
)
SELECT CONCAT(contract_type, N' | ', internet_service, N' | ', payment_type) AS risk_segment,
       contract_type, contract_sort, internet_service, payment_type,
       customers, customer_months, churners, active_customers, current_mrr_usd,
       CAST(monthly_churn_rate AS DECIMAL(8,6)) AS monthly_churn_rate,
       CAST(overall_monthly_churn_rate AS DECIMAL(8,6)) AS overall_monthly_churn_rate,
       CAST(monthly_churn_rate / overall_monthly_churn_rate AS DECIMAL(6,2)) AS churn_lift,
       CAST(customer_share AS DECIMAL(6,4)) AS customer_share,
       CAST(mrr_share AS DECIMAL(6,4)) AS mrr_share,
       CAST(current_mrr_usd * monthly_churn_rate AS DECIMAL(12,2)) AS expected_mrr_loss_usd,
       CASE WHEN customer_share >= 0.05 AND monthly_churn_rate >= 1.5 * overall_monthly_churn_rate AND mrr_share >= 0.10
            THEN 1 ELSE 0 END AS is_high_risk
FROM combined;
GO

/* Số liệu nền cho what-if: quy mô, MRR và churn của từng loại hợp đồng. */
CREATE OR ALTER VIEW mart.v_whatif_contract_base AS
WITH window_stats AS (
    SELECT ct.contract_type, ct.contract_sort,
           COUNT(*) AS customer_months,
           SUM(CAST(f.is_churn_month AS INT)) AS churners,
           SUM(CASE WHEN f.is_churn_month = 1 THEN f.amount_usd ELSE 0 END) AS mrr_lost_usd,
           COUNT(DISTINCT d.date_key) AS months
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_analysis_window = 1
    JOIN mart.dim_contract ct ON ct.contract_key = f.contract_key
    GROUP BY ct.contract_type, ct.contract_sort
), now_stats AS (
    SELECT ct.contract_type, COUNT(*) AS active_customers, SUM(f.amount_usd) AS current_mrr_usd
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_snapshot_month = 1
    JOIN mart.dim_contract ct ON ct.contract_key = f.contract_key
    WHERE f.is_churn_month = 0
    GROUP BY ct.contract_type
)
SELECT w.contract_type, w.contract_sort, n.active_customers, n.current_mrr_usd,
       CAST(n.current_mrr_usd / n.active_customers AS DECIMAL(10,2)) AS arpu_usd,
       w.churners AS churners_in_window,
       CAST(1.0 * w.churners / w.customer_months AS DECIMAL(8,6)) AS monthly_churn_rate,
       CAST(1.0 * w.churners / w.months AS DECIMAL(10,2)) AS avg_churners_per_month,
       CAST(w.mrr_lost_usd / w.months AS DECIMAL(12,2)) AS avg_mrr_lost_per_month_usd
FROM window_stats w JOIN now_stats n ON n.contract_type = w.contract_type;
GO

/* Kết quả kiểm tra chất lượng của batch gần nhất và thống kê bản ghi bị loại, cho trang Data Quality. */
CREATE OR ALTER VIEW mart.v_dq_latest AS
SELECT r.*
FROM mart.dq_check_results r
WHERE r.batch_id = (SELECT TOP (1) batch_id FROM mart.dq_check_results ORDER BY checked_at DESC, dq_id DESC);
GO

CREATE OR ALTER VIEW mart.v_rejected_summary AS
SELECT source_table, reason_code, MIN(reason_detail) AS sample_detail, COUNT(*) AS rejected_rows
FROM clean.rejected_records
GROUP BY source_table, reason_code;
GO
