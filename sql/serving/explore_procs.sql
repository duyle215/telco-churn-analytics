/*
  Lớp phục vụ trang Khám phá trên dashboard.

  Bộ lọc truyền vào dạng JSON: [{"factor": "contract", "value": "Month-to-month"}, ...]
  - Cùng một yếu tố, nhiều giá trị: HOẶC. Khác yếu tố: VÀ.
  - Không dùng SQL động: kế hoạch thực thi được biên dịch một lần rồi tái sử dụng, và không có đường cho SQL injection.
  - Mỗi lần gọi trả về nhiều result set trong một round-trip (không N+1).
*/

CREATE OR ALTER PROCEDURE mart.usp_explore_factors
AS
BEGIN
    SET NOCOUNT ON;
    SELECT f.factor_key, f.factor_label, f.factor_sort, cf.value, MIN(cf.value_sort) AS value_sort, COUNT(*) AS customers
    FROM mart.customer_factor cf
    JOIN mart.dim_factor f ON f.factor_key = cf.factor_key
    JOIN mart.customer_snapshot s ON s.customer_key = cf.customer_key AND s.in_analysis_window = 1
    GROUP BY f.factor_key, f.factor_label, f.factor_sort, cf.value
    ORDER BY f.factor_sort, value_sort;
END
GO

CREATE OR ALTER PROCEDURE mart.usp_explore @filters NVARCHAR(MAX) = N'[]'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @window_start DATE = dbo.fn_config_date('analysis_window_start');
    DECLARE @snapshot DATE = dbo.fn_config_date('snapshot_date');
    DECLARE @snapshot_month DATE = DATEFROMPARTS(YEAR(@snapshot), MONTH(@snapshot), 1);

    CREATE TABLE #f (factor_key VARCHAR(30) NOT NULL, value NVARCHAR(60) NOT NULL, PRIMARY KEY (factor_key, value));
    INSERT INTO #f (factor_key, value)
    SELECT DISTINCT j.factor_key, j.value
    FROM OPENJSON(@filters) WITH (factor_key VARCHAR(30) '$.factor', value NVARCHAR(60) '$.value') j
    WHERE j.factor_key IS NOT NULL AND j.value IS NOT NULL;
    DECLARE @filtered_factors INT = (SELECT COUNT(DISTINCT factor_key) FROM #f);

    /*
      fails = số yếu tố đang lọc mà khách KHÔNG thoả. Mỗi khách có đúng một giá trị cho mỗi yếu tố,
      nên số yếu tố khớp = số dòng customer_factor join được với #f.
    */
    SELECT s.customer_key, s.is_churned, s.window_months, s.customer_status, s.current_mrr_usd,
           s.late_payment_rate, s.first_billing_month,
           @filtered_factors - ISNULL(mt.matched, 0) AS fails,
           CASE WHEN @filtered_factors - ISNULL(mt.matched, 0) = 0 THEN 1 ELSE 0 END AS sel
    INTO #s
    FROM mart.customer_snapshot s
    LEFT JOIN (SELECT cf.customer_key, COUNT(*) AS matched
               FROM mart.customer_factor cf
               JOIN #f f ON f.factor_key = cf.factor_key AND f.value = cf.value
               GROUP BY cf.customer_key) mt ON mt.customer_key = s.customer_key
    WHERE s.in_analysis_window = 1;
    CREATE UNIQUE CLUSTERED INDEX ix_s ON #s (customer_key);

    /* 1. KPI: nhóm đang chọn và toàn công ty trong cùng một lần quét */
    SELECT COUNT(*) AS all_customers, SUM(is_churned) AS all_churners, SUM(window_months) AS all_customer_months,
           SUM(CASE WHEN customer_status = N'Active' THEN 1 ELSE 0 END) AS all_active, SUM(current_mrr_usd) AS all_mrr,
           AVG(CAST(late_payment_rate AS FLOAT)) AS all_late_rate,
           SUM(sel) AS sel_customers, SUM(sel * is_churned) AS sel_churners, SUM(sel * window_months) AS sel_customer_months,
           SUM(CASE WHEN sel = 1 AND customer_status = N'Active' THEN 1 ELSE 0 END) AS sel_active,
           SUM(CASE WHEN sel = 1 THEN current_mrr_usd END) AS sel_mrr,
           AVG(CASE WHEN sel = 1 THEN CAST(late_payment_rate AS FLOAT) END) AS sel_late_rate
    FROM #s;

    /*
      2. Tác động từng yếu tố trong ngữ cảnh hiện tại. Với yếu tố F, khách được tính khi thoả MỌI bộ lọc
         khác F (bỏ qua bộ lọc của chính F để vẫn thấy đủ các giá trị của F):
         - F không bị lọc, hoặc giá trị của khách nằm trong bộ lọc F  -> cần fails = 0
         - F bị lọc và giá trị của khách nằm ngoài bộ lọc F             -> cần fails = 1 (chỉ trượt đúng F)
    */
    SELECT cf.factor_key, cf.value, MIN(cf.value_sort) AS value_sort,
           COUNT(*) AS customers, SUM(s.is_churned) AS churners,
           SUM(s.window_months) AS customer_months, SUM(s.current_mrr_usd) AS current_mrr
    FROM #s s
    JOIN mart.customer_factor cf ON cf.customer_key = s.customer_key
    LEFT JOIN (SELECT DISTINCT factor_key FROM #f) ff ON ff.factor_key = cf.factor_key
    LEFT JOIN #f fv ON fv.factor_key = cf.factor_key AND fv.value = cf.value
    WHERE s.fails = CASE WHEN ff.factor_key IS NULL OR fv.value IS NOT NULL THEN 0 ELSE 1 END
    GROUP BY cf.factor_key, cf.value;

    /* 3. Xu hướng theo tháng: nhóm đang chọn và toàn công ty, kèm chỉ tiêu */
    SELECT d.year_month,
           COUNT(*) AS all_customers, SUM(CAST(f.is_churn_month AS INT)) AS all_churners, SUM(f.amount_usd) AS all_mrr,
           SUM(CASE WHEN f.is_churn_month = 1 THEN f.amount_usd ELSE 0 END) AS all_mrr_lost,
           SUM(s.sel) AS sel_customers, SUM(s.sel * CAST(f.is_churn_month AS INT)) AS sel_churners,
           SUM(CASE WHEN s.sel = 1 THEN f.amount_usd ELSE 0 END) AS sel_mrr,
           SUM(CASE WHEN s.sel = 1 AND f.is_churn_month = 1 THEN f.amount_usd ELSE 0 END) AS sel_mrr_lost,
           MAX(t.churn_rate_target) AS churn_rate_target, MAX(t.mrr_target_usd) AS mrr_target_usd
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key AND d.is_analysis_window = 1
    JOIN #s s ON s.customer_key = f.customer_key
    LEFT JOIN mart.fact_target t ON t.date_key = f.date_key
    GROUP BY d.year_month
    ORDER BY d.year_month;

    /* 4. Ticket theo tháng */
    SELECT d.year_month, COUNT(*) AS all_tickets,
           SUM(CASE WHEN t.category = N'Billing' THEN 1 ELSE 0 END) AS all_billing,
           SUM(s.sel) AS sel_tickets,
           SUM(CASE WHEN s.sel = 1 AND t.category = N'Billing' THEN 1 ELSE 0 END) AS sel_billing
    FROM mart.fact_tickets t
    JOIN mart.dim_date d ON d.date_key = t.created_date_key AND d.is_analysis_window = 1
    JOIN #s s ON s.customer_key = t.customer_key
    GROUP BY d.year_month
    ORDER BY d.year_month;

    /* 5. Retention: khách còn hoạt động ở tháng thứ k kể từ kỳ cước đầu (chỉ cohort bắt đầu trong cửa sổ,
          tránh thiên lệch sống sót) */
    SELECT DATEDIFF(MONTH, s.first_billing_month, d.[date]) AS k, COUNT(*) AS all_active, SUM(s.sel) AS sel_active
    FROM mart.fact_billing f
    JOIN mart.dim_date d ON d.date_key = f.date_key
    JOIN #s s ON s.customer_key = f.customer_key
    WHERE s.first_billing_month >= @window_start
    GROUP BY DATEDIFF(MONTH, s.first_billing_month, d.[date]);

    /* 6. Mẫu số retention: mỗi khách quan sát được tối đa bao nhiêu tháng tính tới snapshot */
    SELECT DATEDIFF(MONTH, first_billing_month, @snapshot_month) AS max_k, COUNT(*) AS all_customers, SUM(sel) AS sel_customers
    FROM #s
    WHERE first_billing_month >= @window_start
    GROUP BY DATEDIFF(MONTH, first_billing_month, @snapshot_month);
END
GO

CREATE OR ALTER PROCEDURE mart.usp_explore_customers @filters NVARCHAR(MAX) = N'[]', @limit INT = 1000
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #f (factor_key VARCHAR(30) NOT NULL, value NVARCHAR(60) NOT NULL, PRIMARY KEY (factor_key, value));
    INSERT INTO #f (factor_key, value)
    SELECT DISTINCT j.factor_key, j.value
    FROM OPENJSON(@filters) WITH (factor_key VARCHAR(30) '$.factor', value NVARCHAR(60) '$.value') j
    WHERE j.factor_key IS NOT NULL AND j.value IS NOT NULL;
    DECLARE @filtered_factors INT = (SELECT COUNT(DISTINCT factor_key) FROM #f);

    SELECT TOP (@limit) s.customer_id, s.contract_type, s.internet_service, s.payment_method, s.tenure_months,
           s.current_mrr_usd, s.tickets, s.billing_tickets, s.late_payment_rate, s.tech_support, s.addon_count
    FROM mart.customer_snapshot s
    LEFT JOIN (SELECT cf.customer_key, COUNT(*) AS matched
               FROM mart.customer_factor cf
               JOIN #f f ON f.factor_key = cf.factor_key AND f.value = cf.value
               GROUP BY cf.customer_key) mt ON mt.customer_key = s.customer_key
    WHERE s.in_analysis_window = 1 AND s.customer_status = N'Active'
      AND ISNULL(mt.matched, 0) = @filtered_factors
    ORDER BY s.current_mrr_usd DESC, s.tickets DESC;
END
GO
