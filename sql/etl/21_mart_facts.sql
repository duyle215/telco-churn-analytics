/*
  clean -> mart: các bảng fact. Nạp lại toàn bộ trong 1 transaction (TRUNCATE + INSERT).
  Mỗi proc so số dòng kỳ vọng với số dòng đã ghi; lệch là THROW, không để mất dòng âm thầm.
*/

CREATE OR ALTER PROCEDURE mart.usp_load_fact_billing @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_billing', N'mart.fact_billing', NULL, @log_id OUTPUT;
    BEGIN TRY
        /*
          Grain lấy từ CRM (mọi tháng khách có tính cước theo hợp đồng), không lấy từ bảng hoá đơn.
          Lý do: tháng billing gặp sự cố không có hoá đơn, nếu lấy theo hoá đơn thì khách "biến mất"
          một tháng và churn rate, số khách, MRR của tháng đó đều sai.
        */
        -- Sinh tháng bằng bảng số đếm rồi join dim_date theo phép bằng: join theo khoảng (BETWEEN) với dim_date
        -- bị SQL Server chạy thành nested loop, đọc ~14 triệu trang và mất ~37 giây.
        WITH n AS (
            SELECT TOP (1000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i FROM sys.all_objects
        )
        SELECT k.customer_id, d.date_key, d.[date] AS billing_month,
               n.i + 1 AS tenure_month_no,
               k.monthly_charges, k.churn_month
        INTO #m
        FROM clean.contracts k
        JOIN n ON n.i <= DATEDIFF(MONTH, k.first_billing_month, k.last_billing_month)
        JOIN mart.dim_date d ON d.[date] = DATEADD(MONTH, n.i, k.first_billing_month)
        WHERE k.first_billing_month IS NOT NULL;
        SET @expected = @@ROWCOUNT;

        SELECT m.*, i.invoice_id, i.amount_usd, i.amount_source, i.due_date,
               p.paid_amount, p.last_payment_date
        INTO #f
        FROM #m m
        LEFT JOIN clean.invoices i ON i.customer_id = m.customer_id AND i.billing_month = m.billing_month
        LEFT JOIN (SELECT invoice_id, SUM(amount_usd) AS paid_amount, MAX(payment_date) AS last_payment_date
                   FROM clean.payments GROUP BY invoice_id) p ON p.invoice_id = i.invoice_id;

        -- Tháng thiếu hoá đơn: ước lượng bằng trung bình hoá đơn liền trước và liền sau của chính khách đó
        -- (mức cước khách thường ổn định), thiếu một phía thì dùng phía còn lại, không có cả hai thì dùng giá gói.
        UPDATE f
        SET amount_usd = CASE WHEN prev.amount_usd IS NOT NULL AND nxt.amount_usd IS NOT NULL
                                  THEN ROUND((prev.amount_usd + nxt.amount_usd) / 2, 2)
                              ELSE COALESCE(prev.amount_usd, nxt.amount_usd, f.monthly_charges) END,
            amount_source = 'IMPUTED_MISSING_INVOICE'
        FROM #f f
        OUTER APPLY (SELECT TOP (1) amount_usd FROM clean.invoices x
                     WHERE x.customer_id = f.customer_id AND x.billing_month < f.billing_month
                     ORDER BY x.billing_month DESC) prev
        OUTER APPLY (SELECT TOP (1) amount_usd FROM clean.invoices x
                     WHERE x.customer_id = f.customer_id AND x.billing_month > f.billing_month
                     ORDER BY x.billing_month ASC) nxt
        WHERE f.invoice_id IS NULL;

        -- Tra surrogate key một lần cho mỗi khách (7 nghìn dòng) thay vì join 9 cột dịch vụ trên từng khách-tháng.
        SELECT k.customer_id, dc.customer_key, ct.contract_key, ds.service_key, pm.payment_method_key
        INTO #keys
        FROM clean.contracts k
        JOIN mart.dim_customer dc ON dc.customer_id = k.customer_id
        JOIN mart.dim_contract ct ON ct.contract_type = k.contract_type
                                 AND ct.paperless_billing = CASE k.is_paperless_billing WHEN 1 THEN N'Yes' ELSE N'No' END
        JOIN mart.dim_payment_method pm ON pm.payment_method = k.payment_method
        JOIN clean.services sv ON sv.customer_id = k.customer_id
        JOIN mart.dim_service ds ON ds.phone_service = sv.phone_service AND ds.multiple_lines = sv.multiple_lines
                                AND ds.internet_service = sv.internet_service AND ds.online_security = sv.online_security
                                AND ds.online_backup = sv.online_backup AND ds.device_protection = sv.device_protection
                                AND ds.tech_support = sv.tech_support AND ds.streaming_tv = sv.streaming_tv
                                AND ds.streaming_movies = sv.streaming_movies;
        CREATE UNIQUE CLUSTERED INDEX ix_tmp_keys ON #keys (customer_id);

        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_billing;
            INSERT INTO mart.fact_billing WITH (TABLOCK) (customer_key, date_key, contract_key, service_key, payment_method_key,
                invoice_id, tenure_month_no, amount_usd, usd_vnd_rate, amount_vnd, amount_source, is_imputed,
                is_first_month, is_churn_month, is_paid, paid_amount_usd, payment_date, days_after_due, is_late)
            SELECT ky.customer_key, f.date_key, ky.contract_key, ky.service_key, ky.payment_method_key,
                   f.invoice_id, f.tenure_month_no, f.amount_usd, fx.usd_vnd,
                   ROUND(f.amount_usd * fx.usd_vnd, 0),
                   f.amount_source,
                   CASE WHEN f.amount_source LIKE 'IMPUTED%' THEN 1 ELSE 0 END,
                   CASE WHEN f.tenure_month_no = 1 THEN 1 ELSE 0 END,
                   CASE WHEN f.billing_month = f.churn_month THEN 1 ELSE 0 END,
                   CASE WHEN f.invoice_id IS NULL THEN NULL WHEN f.paid_amount IS NOT NULL THEN 1 ELSE 0 END,
                   f.paid_amount, f.last_payment_date,
                   DATEDIFF(DAY, f.due_date, f.last_payment_date),
                   CASE WHEN f.last_payment_date IS NULL THEN NULL WHEN f.last_payment_date > f.due_date THEN 1 ELSE 0 END
            FROM #f f
            JOIN #keys ky ON ky.customer_id = f.customer_id
            JOIN clean.fx_rates fx ON fx.rate_month = f.billing_month;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected
                THROW 50010, N'fact_billing: số dòng ghi khác số khách-tháng kỳ vọng (thiếu dimension hoặc tỷ giá)', 1;
        COMMIT;

        SET @msg = CONCAT(N'customer-months ', @expected, N'; imputed ',
                          (SELECT COUNT(*) FROM #f WHERE amount_source = 'IMPUTED_MISSING_INVOICE'));
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_fact_tickets @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_tickets', N'mart.fact_tickets', NULL, @log_id OUTPUT;
    BEGIN TRY
        SET @expected = (SELECT COUNT(*) FROM clean.tickets);
        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_tickets;
            INSERT INTO mart.fact_tickets (ticket_id, customer_key, created_date_key, resolved_date_key, contract_key,
                service_key, payment_method_key, created_at, resolved_at, category, priority, channel, status,
                resolution_hours, is_open, days_before_churn, is_within_90d_before_churn)
            SELECT t.ticket_id, dc.customer_key,
                   YEAR(t.created_at) * 10000 + MONTH(t.created_at) * 100 + DAY(t.created_at),
                   CASE WHEN t.resolved_at IS NOT NULL THEN YEAR(t.resolved_at) * 10000 + MONTH(t.resolved_at) * 100 + DAY(t.resolved_at) END,
                   ct.contract_key, ds.service_key, pm.payment_method_key,
                   t.created_at, t.resolved_at, t.category, t.priority, t.channel, t.status, t.resolution_hours,
                   CASE WHEN t.status = N'Open' THEN 1 ELSE 0 END,
                   CASE WHEN k.end_date IS NOT NULL THEN DATEDIFF(DAY, CAST(t.created_at AS DATE), k.end_date) END,
                   CASE WHEN k.end_date IS NOT NULL AND DATEDIFF(DAY, CAST(t.created_at AS DATE), k.end_date) BETWEEN 0 AND 90
                        THEN 1 ELSE 0 END
            FROM clean.tickets t
            JOIN mart.dim_customer dc ON dc.customer_id = t.customer_id
            JOIN clean.contracts k ON k.customer_id = t.customer_id
            JOIN mart.dim_contract ct ON ct.contract_type = k.contract_type
                                     AND ct.paperless_billing = CASE k.is_paperless_billing WHEN 1 THEN N'Yes' ELSE N'No' END
            JOIN mart.dim_payment_method pm ON pm.payment_method = k.payment_method
            JOIN clean.services sv ON sv.customer_id = t.customer_id
            JOIN mart.dim_service ds ON ds.phone_service = sv.phone_service AND ds.multiple_lines = sv.multiple_lines
                                    AND ds.internet_service = sv.internet_service AND ds.online_security = sv.online_security
                                    AND ds.online_backup = sv.online_backup AND ds.device_protection = sv.device_protection
                                    AND ds.tech_support = sv.tech_support AND ds.streaming_tv = sv.streaming_tv
                                    AND ds.streaming_movies = sv.streaming_movies;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected
                THROW 50011, N'fact_tickets: số dòng ghi khác số ticket trong clean', 1;
        COMMIT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_fact_target @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @expected INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_fact_target', N'mart.fact_target', NULL, @log_id OUTPUT;
    BEGIN TRY
        SET @expected = (SELECT COUNT(*) FROM clean.targets);
        BEGIN TRAN;
            TRUNCATE TABLE mart.fact_target;
            INSERT INTO mart.fact_target (date_key, churn_rate_target, mrr_target_usd, note)
            SELECT d.date_key, t.churn_rate_target, t.mrr_target_usd, t.note
            FROM clean.targets t JOIN mart.dim_date d ON d.[date] = t.target_month;
            SET @written = @@ROWCOUNT;
            IF @written <> @expected THROW 50012, N'fact_target: tháng chỉ tiêu nằm ngoài dim_date', 1;
        COMMIT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @expected, @written, NULL;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @expected, NULL, @msg;
        THROW;
    END CATCH
END
GO
