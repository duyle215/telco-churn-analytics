/*
  Câu hỏi 5: Tháng nào churn hoặc ticket bất thường (lệch khỏi trung bình 24 tháng quá 2 độ lệch chuẩn)?
  Nguồn: mart.v_anomaly_monthly (toàn bộ khách và từng loại internet; churn rate, tổng ticket, ticket Billing).

  Insight:
  - Bắt được sự kiện tăng giá Fiber 03/2025:
      Churn toàn bộ 2025-04 = 3,10% (ngưỡng trên 2,53%, z = 3,28); churn Fiber 2025-04 = 6,07% (ngưỡng 4,77%, z = 3,28).
      Ticket 2025-03 = 552 (bình quân 331, z = 3,54); ticket Billing 2025-03 = 285 so với bình quân 90 (z = 3,69).
  - Ticket bất thường xuất hiện trước churn khoảng 1 tháng (ticket đỉnh 2025-03, churn đỉnh 2025-04):
    số ticket Billing là tín hiệu cảnh báo sớm, nên theo dõi hằng tuần.
  - Churn 2025-03 (2,49%) và 2025-05 (2,15%) cũng cao nhưng không vượt ngưỡng, vì chính tháng đỉnh đã thổi phồng
    độ lệch chuẩn (hiệu ứng che lấp). Khi theo dõi vận hành nên tính ngưỡng từ các tháng bình thường trước đó
    (rolling baseline) thay vì cả chuỗi.
  - Vài điểm vượt nhẹ (z 2,0-2,7) ở nhóm nhỏ (ticket DSL 2025-08/11, khách không dùng internet) là nhiễu:
    với 12 chuỗi x 24 tháng, có vài điểm vượt 2σ là bình thường. Nên thêm điều kiện z > 3 hoặc vượt 2 tháng liền.
*/
SELECT year_month, segment, metric, value, mean_value, upper_bound, z_score
FROM mart.v_anomaly_monthly
WHERE is_anomaly = 1
ORDER BY metric, segment, year_month;

-- Chuỗi đầy đủ churn rate Fiber và ticket Billing để thấy hình dạng đợt bất thường.
SELECT year_month, metric, value, upper_bound, z_score, is_anomaly
FROM mart.v_anomaly_monthly
WHERE (segment = N'Fiber optic' AND metric = N'Churn rate') OR (segment = N'All' AND metric = N'Billing tickets')
ORDER BY metric, year_month;
