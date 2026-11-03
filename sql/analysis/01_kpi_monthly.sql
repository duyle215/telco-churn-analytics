/*
  Câu hỏi 1: KPI theo tháng (số khách, churn rate, MRR, MRR mất do churn, ARPU) so với chỉ tiêu.
  Nguồn: mart.v_kpi_monthly (định nghĩa chỉ số ở đầu sql/views/mart_views.sql).

  Insight (batch ETL gần nhất, cửa sổ 2024-01..2025-12):
  - Số khách có tính cước tăng 4.284 -> 5.240 (+22%), MRR tăng 283.226 -> 322.470 USD (+13,9%).
  - Churn rate bình quân 1,66%/tháng nhưng vượt chỉ tiêu ở 9/12 tháng năm 2024 (chỉ tiêu 1,39%)
    và 10/12 tháng năm 2025 (chỉ tiêu 1,28%): chỉ tiêu churn không đạt một cách có hệ thống.
  - 2025-03 MRR tăng +8,0% so với tháng trước (tăng giá Fiber 15%), kéo MRR vượt chỉ tiêu +6,6%.
    Nhưng ngay sau đó MRR mất do churn lên đỉnh 12.018 USD ở 2025-04 (gấp ~2,4 lần mức thường ~5.000)
    và MRR giảm 4 tháng liên tiếp (2025-04..07): phần lợi từ tăng giá bị churn ăn lại một phần.
  - MRR chỉ hụt chỉ tiêu ở 2024-11..2025-02 (-0,06% đến -0,84%), các tháng khác đều vượt.
  - ARPU giảm dần 66,11 -> 61,54 USD (trừ bước nhảy khi tăng giá); cần tách theo tenure/gói cước
    để biết nguyên nhân trước khi kết luận.
  - Lưu ý: 2025-12 có 248 khách mới (gấp đôi bình thường) là đặc điểm của dữ liệu gốc (nhiều khách tenure = 1),
    không nên đọc là tăng trưởng đột biến. MRR tháng 2024-08 là số ước lượng (sự cố billing).
*/
SELECT year_month, customers, new_customers, churners,
       churn_rate, churn_rate_target, churn_vs_target,
       mrr_usd, mrr_target_usd, mrr_vs_target_pct, mrr_mom_pct,
       mrr_lost_usd, arpu_usd, imputed_rows
FROM mart.v_kpi_monthly
WHERE is_analysis_window = 1
ORDER BY date_key;

-- Tổng hợp theo năm: số tháng không đạt chỉ tiêu.
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
