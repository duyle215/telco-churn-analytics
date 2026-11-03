/*
  Câu hỏi 4: Khách được giữ lại bao lâu, theo tháng bắt đầu (cohort)?
  Nguồn: mart.v_cohort_retention. Chỉ lấy cohort có kỳ cước đầu tiên từ 2024-01 (cohort 2023-12..2025-11),
  vì cohort cũ hơn chỉ còn những khách đã sống sót tới 2024 (survivorship bias).

  Insight (retention bình quân có trọng số theo quy mô cohort):
  - Tháng 1: 86,1%; tháng 3: 78,2%; tháng 6: 71,2%; tháng 12: 61,1%; tháng 18: 55,0%.
    Mất 13,9 điểm % ngay sau kỳ cước đầu tiên: giai đoạn onboarding là điểm rò rỉ lớn nhất.
  - Các cohort 2025-01..2025-04 chỉ giữ được 70,9-73,3% sau 3 tháng, so với 74-84% ở các cohort 2024:
    3 tháng đầu của họ trùng đợt tăng giá Fiber.
  - Cohort 2024-04 có retention 12 tháng thấp nhất (49,2%); tháng thứ 12 của cohort này rơi đúng 2025-04.
*/
-- Ma trận retention (cohort x số tháng kể từ kỳ cước đầu).
SELECT cohort_label, cohort_size, month_offset, active_customers, retention_rate
FROM mart.v_cohort_retention
ORDER BY cohort_month, month_offset;

-- Đường retention bình quân có trọng số; mỗi mốc chỉ tính các cohort đã đủ tuổi tới mốc đó.
SELECT month_offset,
       COUNT(*) AS cohorts,
       SUM(cohort_size) AS customers,
       CAST(1.0 * SUM(active_customers) / SUM(cohort_size) AS DECIMAL(6,4)) AS weighted_retention
FROM mart.v_cohort_retention
GROUP BY month_offset
ORDER BY month_offset;

-- Retention tại các mốc 3/6/12 tháng của từng cohort.
SELECT cohort_label, cohort_size,
       MAX(CASE WHEN month_offset = 3 THEN retention_rate END) AS retention_m3,
       MAX(CASE WHEN month_offset = 6 THEN retention_rate END) AS retention_m6,
       MAX(CASE WHEN month_offset = 12 THEN retention_rate END) AS retention_m12
FROM mart.v_cohort_retention
GROUP BY cohort_month, cohort_label, cohort_size
ORDER BY cohort_month;
