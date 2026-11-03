/* stg -> clean cho Billing: invoices, payments. Chạy sau CRM vì cần đối chiếu khoá với clean.customers/contracts. */

CREATE OR ALTER PROCEDURE clean.usp_load_invoices @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_invoices', N'clean.invoices', N'BILLING', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.invoice_id)) AS invoice_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               s.billing_month, s.invoice_date, s.due_date,
               s.amount_usd AS amount_raw,
               CAST(NULL AS DECIMAL(10,2)) AS amount_usd,
               CAST(NULL AS VARCHAR(30)) AS amount_source,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #i
        FROM stg.billing_invoices s;
        SET @read = @@ROWCOUNT;
        CREATE CLUSTERED INDEX ix_tmp_i ON #i (customer_id, billing_month);

        UPDATE #i SET reject_reason = 'MISSING_KEY', reject_detail = N'invoice_id hoặc customer_id rỗng'
        WHERE NULLIF(invoice_id, N'') IS NULL OR NULLIF(customer_id, N'') IS NULL;

        WITH ranked AS (
            SELECT reject_reason, reject_detail, ROW_NUMBER() OVER (PARTITION BY invoice_id ORDER BY stg_row_id) AS rn
            FROM #i WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Trùng invoice_id' WHERE rn > 1;

        -- Billing và CRM là hai hệ thống không có khoá ngoại; hoá đơn của khách không có trong CRM
        -- (tài khoản test, khách bị xoá) không gán được cho ai nên không thể vào kho.
        UPDATE i SET reject_reason = 'ORPHAN_CUSTOMER', reject_detail = CONCAT(N'customer_id ', i.customer_id, N' không có trong CRM')
        FROM #i i
        WHERE i.reject_reason IS NULL AND NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = i.customer_id);

        UPDATE #i SET reject_reason = 'INVALID_DATE', reject_detail = N'billing_month không phải ngày đầu tháng hoặc due_date < invoice_date'
        WHERE reject_reason IS NULL
          AND (billing_month IS NULL OR DAY(billing_month) <> 1 OR invoice_date IS NULL OR due_date < invoice_date);

        UPDATE i SET reject_reason = 'OUTSIDE_CONTRACT_PERIOD',
                     reject_detail = N'Kỳ cước nằm ngoài vòng đời hợp đồng trong CRM (hoặc khách không có hợp đồng hợp lệ)'
        FROM #i i
        LEFT JOIN clean.contracts k ON k.customer_id = i.customer_id
        WHERE i.reject_reason IS NULL
          AND (k.customer_id IS NULL OR i.billing_month NOT BETWEEN k.first_billing_month AND k.last_billing_month);

        WITH ranked AS (
            SELECT reject_reason, reject_detail,
                   ROW_NUMBER() OVER (PARTITION BY customer_id, billing_month ORDER BY stg_row_id) AS rn
            FROM #i WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_PERIOD', reject_detail = N'Khách có nhiều hoá đơn trong cùng kỳ' WHERE rn > 1;

        /*
          Sửa số tiền thay vì loại, vì hoá đơn vẫn có thật (khách vẫn dùng dịch vụ tháng đó):
          - Âm: hệ thống không có hoá đơn âm (giảm trừ đi qua chứng từ khác) nên coi là nhập nhầm dấu.
          - NULL: lấy từ tổng thanh toán của chính hoá đơn đó (billing lưu số tiền thanh toán chính xác).
          - NULL và chưa thanh toán: ước lượng bằng hoá đơn liền trước của khách, rồi liền sau,
            cuối cùng là giá gói hiện tại trong CRM. Mỗi cách đều được ghi lại ở amount_source.
        */
        WITH pay AS (
            SELECT LTRIM(RTRIM(invoice_id)) AS invoice_id, SUM(amount_usd) AS amount
            FROM stg.billing_payments GROUP BY LTRIM(RTRIM(invoice_id))
        )
        UPDATE i
        SET amount_usd = CASE WHEN i.amount_raw >= 0 THEN i.amount_raw
                              WHEN i.amount_raw < 0 THEN -i.amount_raw
                              ELSE p.amount END,
            amount_source = CASE WHEN i.amount_raw >= 0 THEN 'SOURCE'
                                 WHEN i.amount_raw < 0 THEN 'SIGN_CORRECTED'
                                 WHEN p.amount IS NOT NULL THEN 'FROM_PAYMENT' END
        FROM #i i
        LEFT JOIN pay p ON p.invoice_id = i.invoice_id
        WHERE i.reject_reason IS NULL;

        UPDATE i
        SET amount_usd = COALESCE(prev.amount_usd, nxt.amount_usd, k.monthly_charges),
            amount_source = CASE WHEN prev.amount_usd IS NOT NULL THEN 'IMPUTED_PREV_INVOICE'
                                 WHEN nxt.amount_usd IS NOT NULL THEN 'IMPUTED_NEXT_INVOICE'
                                 ELSE 'IMPUTED_CONTRACT_PRICE' END
        FROM #i i
        OUTER APPLY (SELECT TOP (1) x.amount_usd FROM #i x
                     WHERE x.customer_id = i.customer_id AND x.billing_month < i.billing_month
                       AND x.reject_reason IS NULL AND x.amount_source IN ('SOURCE', 'SIGN_CORRECTED', 'FROM_PAYMENT')
                     ORDER BY x.billing_month DESC) prev
        OUTER APPLY (SELECT TOP (1) x.amount_usd FROM #i x
                     WHERE x.customer_id = i.customer_id AND x.billing_month > i.billing_month
                       AND x.reject_reason IS NULL AND x.amount_source IN ('SOURCE', 'SIGN_CORRECTED', 'FROM_PAYMENT')
                     ORDER BY x.billing_month ASC) nxt
        LEFT JOIN clean.contracts k ON k.customer_id = i.customer_id
        WHERE i.reject_reason IS NULL AND i.amount_usd IS NULL;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, invoice_id, reject_reason, reject_detail FROM #i WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.invoices;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.billing_invoices';
            INSERT INTO clean.invoices (invoice_id, customer_id, billing_month, invoice_date, due_date,
                                        amount_usd, amount_source, stg_row_id)
            SELECT invoice_id, customer_id, billing_month, invoice_date, due_date, amount_usd, amount_source, stg_row_id
            FROM #i WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.billing_invoices';
        COMMIT;

        EXEC clean.usp_reject_summary @msg OUTPUT;
        SELECT @msg = CONCAT(@msg, N' | amount_source: ',
                             (SELECT STRING_AGG(CONCAT(amount_source, N'=', n), N', ')
                              FROM (SELECT amount_source, COUNT(*) n FROM #i WHERE reject_reason IS NULL
                                    AND amount_source <> 'SOURCE' GROUP BY amount_source) x));
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @read, @written, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @read, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE clean.usp_load_payments @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_payments', N'clean.payments', N'BILLING', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.payment_id)) AS payment_id,
               LTRIM(RTRIM(s.invoice_id)) AS invoice_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               s.payment_date, s.amount_usd,
               CASE UPPER(LTRIM(RTRIM(s.payment_method)))
                    WHEN 'ELECTRONIC CHECK' THEN N'Electronic check' WHEN 'MAILED CHECK' THEN N'Mailed check'
                    WHEN 'BANK TRANSFER (AUTOMATIC)' THEN N'Bank transfer (automatic)'
                    WHEN 'CREDIT CARD (AUTOMATIC)' THEN N'Credit card (automatic)' END AS payment_method,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #p
        FROM stg.billing_payments s;
        SET @read = @@ROWCOUNT;

        UPDATE #p SET reject_reason = 'MISSING_KEY', reject_detail = N'payment_id hoặc invoice_id rỗng'
        WHERE NULLIF(payment_id, N'') IS NULL OR NULLIF(invoice_id, N'') IS NULL;

        WITH ranked AS (
            SELECT reject_reason, reject_detail, ROW_NUMBER() OVER (PARTITION BY payment_id ORDER BY stg_row_id) AS rn
            FROM #p WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Trùng payment_id' WHERE rn > 1;

        -- Thanh toán đi theo hoá đơn: hoá đơn đã bị loại thì thanh toán cũng bị loại, kèm lý do gốc.
        UPDATE p SET reject_reason = 'ORPHAN_INVOICE',
                     reject_detail = COALESCE(N'Hoá đơn đã bị loại ở bước invoices: ' + r.reason_code,
                                              N'invoice_id không có trong billing')
        FROM #p p
        OUTER APPLY (SELECT TOP (1) reason_code FROM clean.rejected_records
                     WHERE source_table = N'stg.billing_invoices' AND business_key = p.invoice_id) r
        WHERE p.reject_reason IS NULL AND NOT EXISTS (SELECT 1 FROM clean.invoices i WHERE i.invoice_id = p.invoice_id);

        UPDATE p SET reject_reason = 'CUSTOMER_MISMATCH', reject_detail = N'customer_id của thanh toán khác với hoá đơn'
        FROM #p p JOIN clean.invoices i ON i.invoice_id = p.invoice_id
        WHERE p.reject_reason IS NULL AND p.customer_id <> i.customer_id;

        UPDATE #p SET reject_reason = 'INVALID_VALUE', reject_detail = N'Số tiền <= 0, thiếu ngày hoặc phương thức không hợp lệ'
        WHERE reject_reason IS NULL
          AND (amount_usd IS NULL OR amount_usd <= 0 OR payment_date IS NULL OR payment_method IS NULL);

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, payment_id, reject_reason, reject_detail FROM #p WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.payments;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.billing_payments';
            INSERT INTO clean.payments (payment_id, invoice_id, customer_id, payment_date, amount_usd, payment_method,
                                        days_after_due, is_late, stg_row_id)
            SELECT p.payment_id, p.invoice_id, p.customer_id, p.payment_date, p.amount_usd, p.payment_method,
                   DATEDIFF(DAY, i.due_date, p.payment_date),
                   CASE WHEN p.payment_date > i.due_date THEN 1 ELSE 0 END,
                   p.stg_row_id
            FROM #p p JOIN clean.invoices i ON i.invoice_id = p.invoice_id
            WHERE p.reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.billing_payments';
        COMMIT;

        EXEC clean.usp_reject_summary @msg OUTPUT;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', @read, @written, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', @read, NULL, @msg;
        THROW;
    END CATCH
END
GO
