/*
  Câu hỏi 6: Nhóm khách nào vừa đông, vừa churn cao, vừa đóng góp MRR lớn?
  Phân khúc = loại hợp đồng x loại internet x hình thức thanh toán (Automatic/Manual), tổng 18 phân khúc.
  Nguồn: mart.v_risk_segments. Ngưỡng rủi ro cao: >= 5% khách, churn >= 1,5 lần bình quân, >= 10% MRR hiện tại.

  Insight:
  - Chỉ một phân khúc thoả cả 3 điều kiện: Month-to-month | Fiber optic | Manual
    (21,4% khách trong cửa sổ, churn 5,46%/tháng = 3,29 lần bình quân 1,66%, 17,0% MRR hiện tại = 53.883 USD).
  - MRR dự kiến mất mỗi tháng của phân khúc này là 2.941 USD, bằng 48,9% tổng MRR dự kiến mất của toàn công ty
    (6.011 USD/tháng). Ba phân khúc Month-to-month đứng đầu chiếm 80,4%.
  - Cùng Month-to-month | Fiber nhưng thanh toán tự động thì churn chỉ 2,78%/tháng, khoảng một nửa:
    chuyển khách sang thanh toán tự động là đòn bẩy rẻ, cần thử nghiệm A/B trước khi kết luận nhân quả.
  - Danh sách khách cụ thể để chăm sóc: truy vấn cuối (drill-through), ưu tiên theo cước hiện tại và số ticket.
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

-- Drill-through: khách đang hoạt động thuộc phân khúc rủi ro cao.
SELECT p.customer_id, p.tenure_months, p.current_mrr_usd, p.tickets, p.billing_tickets,
       p.late_payment_rate, p.tech_support, p.addon_count, p.payment_method
FROM mart.v_customer_profile p
JOIN mart.v_risk_segments r ON r.risk_segment = p.risk_segment AND r.is_high_risk = 1
WHERE p.customer_status = N'Active'
ORDER BY p.current_mrr_usd DESC, p.tickets DESC;
