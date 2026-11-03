/*
  Câu hỏi 7: Số liệu nền cho what-if, và ước lượng: nếu X% khách Month-to-month đang hoạt động chuyển sang
  hợp đồng 1 năm thì giữ lại được bao nhiêu MRR?
  Nguồn: mart.v_whatif_contract_base.

  Giả định của mô hình:
  - Khách chuyển đổi mang churn rate theo tháng của nhóm One year và giữ nguyên ARPU Month-to-month
    (chưa tính chiết khấu để thuyết phục khách ký dài hạn).
  - Churn mỗi tháng là hằng số; số khách còn lại sau k tháng = N x (1 - churn)^k.
  - Đây là chênh lệch tương quan giữa hai nhóm, chưa phải nhân quả: khách tự nguyện chuyển đổi có thể vốn đã ít rủi ro hơn,
    nên kết quả là cận trên. Cần thử nghiệm có nhóm đối chứng.

  Insight:
  - Month-to-month: 2.220 khách đang hoạt động, MRR 136.455 USD, churn 3,79%/tháng, gấp 7 lần One year (0,54%)
    và 30 lần Two year (0,12%). Nhóm này mất bình quân 69 khách và 5.035 USD MRR mỗi tháng, chiếm 86,8%
    MRR mất do churn của toàn công ty (5.798 USD/tháng).
  - Chuyển 20% (444 khách) sang One year: tránh ~14 khách rời đi ngay tháng đầu; sau 12 tháng còn thêm 137 khách,
    MRR tháng thứ 12 cao hơn 8.404 USD (2,6% MRR hiện tại); doanh thu giữ thêm trong 12 tháng 59.162 USD.
    Kịch bản 10%: 29.581 USD; 30%: 88.744 USD (tuyến tính theo tỷ lệ chuyển đổi).
  - Chiết khấu tối đa để vẫn hoà vốn trong 12 tháng là ~18,7% giá cước (không phụ thuộc tỷ lệ chuyển đổi).
    Ưu đãi 10-15% khi ký 1 năm là vùng an toàn để thử nghiệm.
*/
SELECT contract_type, active_customers, current_mrr_usd, arpu_usd,
       churners_in_window, monthly_churn_rate, avg_churners_per_month, avg_mrr_lost_per_month_usd
FROM mart.v_whatif_contract_base
ORDER BY contract_sort;

-- Kịch bản chuyển 10% / 20% / 30% khách Month-to-month sang One year, tầm nhìn 12 tháng.
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
       -- Mức chiết khấu tối đa cho khách chuyển đổi mà vẫn hoà vốn trong 12 tháng:
       -- doanh thu giữ thêm / doanh thu của nhóm chuyển đổi nếu họ churn theo nhịp One year.
       CAST(SUM(POWER(1 - s.churn_1y, m.k) - POWER(1 - s.churn_m2m, m.k)) / SUM(POWER(1 - s.churn_1y, m.k)) AS DECIMAL(6,4)) AS break_even_discount_pct
FROM scenario s CROSS JOIN months m
GROUP BY s.shift_pct, s.moved_customers, s.m2m_arpu, s.churn_m2m, s.churn_1y
ORDER BY s.shift_pct;
