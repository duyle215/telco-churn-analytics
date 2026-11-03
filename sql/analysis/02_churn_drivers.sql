/*
  Câu hỏi 2: Churn rate theo từng driver (hợp đồng, tenure, internet, dịch vụ đi kèm, thanh toán...), kèm số khách.
  Nguồn: mart.v_churn_drivers. Đơn vị: khách có tính cước trong cửa sổ 24 tháng (7.032 khách, 1.869 rời đi,
  churn bình quân 26,6% trong 24 tháng). lift_vs_overall = churn của nhóm / churn bình quân.

  Insight:
  - Hợp đồng là driver mạnh nhất: Month-to-month 42,7% so với One year 11,3% và Two year 2,9% (chênh ~15 lần).
  - Tenure: 0-12 tháng churn 47,7%, giảm đều tới 6,6% ở 61-72 tháng; rủi ro tập trung ở năm đầu.
  - Dịch vụ đi kèm có quan hệ đơn điệu rất rõ: 0 add-on 52,2% -> 6 add-on 5,3%.
    Không có Tech support 41,7% so với có 15,2%; không có Online security 41,8% so với 14,6%.
  - Fiber optic 41,9% so với DSL 19,0%; Electronic check 45,3% so với 15-19% các phương thức còn lại.
  - Senior citizen 41,7% so với 23,7%; Paperless billing 33,6% so với 16,4%.
  - Các driver tương quan với nhau (khách Fiber/Electronic check hay đi với Month-to-month) nên không cộng dồn được;
    câu 3 tách ảnh hưởng của loại internet khỏi loại hợp đồng.
*/
SELECT driver, driver_value, customers, churners, churn_rate, lift_vs_overall
FROM mart.v_churn_drivers
ORDER BY driver, COALESCE(sort_order, 99), churn_rate DESC;

-- Khoảng cách giữa nhóm churn cao nhất và thấp nhất của mỗi driver: driver nào phân tách khách tốt nhất.
SELECT driver,
       MAX(churn_rate) AS max_churn_rate,
       MIN(churn_rate) AS min_churn_rate,
       MAX(churn_rate) - MIN(churn_rate) AS spread
FROM mart.v_churn_drivers
GROUP BY driver
ORDER BY spread DESC;
