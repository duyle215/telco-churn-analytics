/*
  Câu hỏi 3: Fiber churn cao hơn DSL thật, hay chỉ vì khách Fiber hay dùng hợp đồng Month-to-month?
  So sánh Fiber và DSL TRONG cùng loại hợp đồng (kiểm soát biến hợp đồng).
  Nguồn: mart.v_churn_internet_by_contract.

  Insight:
  - Khách Fiber đúng là dùng Month-to-month nhiều hơn (68,7% so với 50,6% ở DSL),
    nên một phần chênh lệch thô (41,9% so với 19,0%) đến từ cơ cấu hợp đồng.
  - Nhưng trong cùng loại hợp đồng, Fiber vẫn churn cao hơn rõ rệt:
      Month-to-month 54,6% vs 32,2% (gấp 1,7 lần); One year 19,3% vs 9,3% (2,1 lần); Two year 7,2% vs 1,9% (3,7 lần).
    => Ảnh hưởng của Fiber tồn tại độc lập với loại hợp đồng.
  - Cước bình quân Fiber cao hơn DSL 34-37 USD/tháng trong cùng loại hợp đồng; cộng với đợt tăng giá Fiber 03/2025
    (câu 5), giá là giả thuyết hàng đầu cần kiểm chứng (khảo sát lý do rời đi, so giá đối thủ).
*/
SELECT contract_type, internet_service, customers, churners, churn_rate, avg_monthly_charge_usd
FROM mart.v_churn_internet_by_contract
WHERE internet_service IN (N'Fiber optic', N'DSL')
ORDER BY contract_sort, internet_service;

-- Chênh lệch Fiber - DSL trong từng loại hợp đồng.
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

-- Tỷ trọng hợp đồng trong từng loại internet (giải thích phần chênh lệch do cơ cấu).
SELECT internet_service, contract_type, customers,
       CAST(1.0 * customers / SUM(customers) OVER (PARTITION BY internet_service) AS DECIMAL(6,4)) AS share_in_internet_type
FROM mart.v_churn_internet_by_contract
ORDER BY internet_service, contract_sort;
