/*
  Bộ kiểm tra chất lượng dữ liệu, chạy cuối mỗi batch, lưu vào mart.dq_check_results.
  value_before đo trên stg (dữ liệu gốc), value_after đo trên clean/mart, value_rejected = số dòng bị loại.
  PASS: đạt kỳ vọng. WARN: lệch đã biết và đã xử lý (ví dụ tháng billing sự cố). FAIL: cần điều tra.
*/
CREATE OR ALTER PROCEDURE dbo.usp_run_dq_checks @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @log_id BIGINT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'dq', N'dbo.usp_run_dq_checks', N'mart.dq_check_results', NULL, @log_id OUTPUT;
    BEGIN TRY
        DELETE FROM mart.dq_check_results WHERE batch_id = @batch_id;

        CREATE TABLE #dq (check_id VARCHAR(40), check_group NVARCHAR(50), check_name NVARCHAR(200),
                          object_name NVARCHAR(200), value_before DECIMAL(18,2), value_after DECIMAL(18,2),
                          value_rejected DECIMAL(18,2), expected_rule NVARCHAR(300), status VARCHAR(10), note NVARCHAR(1000));

        DECLARE @rej TABLE (source_table NVARCHAR(128), n INT);
        INSERT INTO @rej SELECT source_table, COUNT(*) FROM clean.rejected_records GROUP BY source_table;

        /* 1. Đối soát số dòng: mọi dòng stg phải có mặt ở clean hoặc ở rejected, không mất dòng nào. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule)
        SELECT CONCAT('ROWS_', UPPER(PARSENAME(x.stg_table, 1))), N'1. Đối soát số dòng', N'stg = clean + rejected',
               CONCAT(x.stg_table, N' -> ', x.clean_table), x.stg_rows, x.clean_rows, ISNULL(r.n, 0),
               N'value_before = value_after + value_rejected'
        FROM (VALUES
            (N'stg.crm_customers', N'clean.customers', (SELECT COUNT(*) FROM stg.crm_customers), (SELECT COUNT(*) FROM clean.customers)),
            (N'stg.crm_contracts', N'clean.contracts', (SELECT COUNT(*) FROM stg.crm_contracts), (SELECT COUNT(*) FROM clean.contracts)),
            (N'stg.crm_services', N'clean.services', (SELECT COUNT(*) FROM stg.crm_services), (SELECT COUNT(*) FROM clean.services)),
            (N'stg.billing_invoices', N'clean.invoices', (SELECT COUNT(*) FROM stg.billing_invoices), (SELECT COUNT(*) FROM clean.invoices)),
            (N'stg.billing_payments', N'clean.payments', (SELECT COUNT(*) FROM stg.billing_payments), (SELECT COUNT(*) FROM clean.payments)),
            (N'stg.ticket_support_tickets', N'clean.tickets', (SELECT COUNT(*) FROM stg.ticket_support_tickets), (SELECT COUNT(*) FROM clean.tickets)),
            (N'stg.finance_targets_cells', N'clean.targets', (SELECT COUNT(*) FROM (SELECT DISTINCT sheet_name, excel_row FROM stg.finance_targets_cells) t), (SELECT COUNT(*) FROM clean.targets)),
            (N'stg.api_fx_rates', N'clean.fx_rates', (SELECT COUNT(*) FROM stg.api_fx_rates), (SELECT COUNT(*) FROM clean.fx_rates))
        ) x(stg_table, clean_table, stg_rows, clean_rows)
        LEFT JOIN @rej r ON r.source_table = x.stg_table;
        UPDATE #dq SET status = CASE WHEN value_before = value_after + value_rejected THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'1. Đối soát số dòng';

        /* 2. Từng loại lỗi: đếm trước (stg) và sau (clean) khi làm sạch. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, note)
        SELECT 'ERR_DUPLICATE_CUSTOMER', N'2. Lỗi trước/sau làm sạch', N'Trùng customer_id (sau khi TRIM)', N'customers',
               (SELECT COUNT(*) - COUNT(DISTINCT LTRIM(RTRIM(customer_id))) FROM stg.crm_customers),
               (SELECT COUNT(*) - COUNT(DISTINCT customer_id) FROM clean.customers),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE reason_code = 'DUPLICATE_KEY' AND source_table = N'stg.crm_customers'),
               N'after = 0', N'Giữ bản ghi updated_at mới nhất'
        UNION ALL
        SELECT 'ERR_BOOLEAN_VARIANT', N'2. Lỗi trước/sau làm sạch', N'Giá trị Yes/No không chuẩn (Y, yes, 1, N, 0...)',
               N'customers.partner/dependents, contracts.paperless_billing/churn_flag, services.phone_service',
               (SELECT COUNT(*) FROM stg.crm_customers CROSS APPLY (VALUES (partner), (dependents)) v(x) WHERE x COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No'))
             + (SELECT COUNT(*) FROM stg.crm_contracts CROSS APPLY (VALUES (paperless_billing), (churn_flag)) v(x) WHERE x COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No'))
             + (SELECT COUNT(*) FROM stg.crm_services WHERE phone_service COLLATE Latin1_General_CS_AS NOT IN ('Yes', 'No')),
               0, NULL, N'after = 0',
               N'Clean lưu cờ dạng BIT nên về cấu trúc không thể còn biến thể; so sánh phân biệt hoa thường để bắt "yes"/"YES"'
        UNION ALL
        SELECT 'ERR_WHITESPACE', N'2. Lỗi trước/sau làm sạch', N'Khoảng trắng thừa đầu/cuối (đo bằng DATALENGTH)',
               N'customer_id (customers, services, invoices, tickets), gender, contract_type, payment_method',
               (SELECT COUNT(*) FROM stg.crm_customers WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))) OR DATALENGTH(gender) <> DATALENGTH(LTRIM(RTRIM(gender))))
             + (SELECT COUNT(*) FROM stg.crm_contracts WHERE DATALENGTH(contract_type) <> DATALENGTH(LTRIM(RTRIM(contract_type))) OR DATALENGTH(payment_method) <> DATALENGTH(LTRIM(RTRIM(payment_method))))
             + (SELECT COUNT(*) FROM stg.crm_services WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM stg.billing_invoices WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM stg.ticket_support_tickets WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id)))),
               (SELECT COUNT(*) FROM clean.customers WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))) OR DATALENGTH(gender) <> DATALENGTH(LTRIM(RTRIM(gender))))
             + (SELECT COUNT(*) FROM clean.contracts WHERE DATALENGTH(contract_type) <> DATALENGTH(LTRIM(RTRIM(contract_type))) OR DATALENGTH(payment_method) <> DATALENGTH(LTRIM(RTRIM(payment_method))))
             + (SELECT COUNT(*) FROM clean.services WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM clean.invoices WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id))))
             + (SELECT COUNT(*) FROM clean.tickets WHERE DATALENGTH(customer_id) <> DATALENGTH(LTRIM(RTRIM(customer_id)))),
               NULL, N'after = 0',
               N'Dùng DATALENGTH vì SQL Server bỏ qua khoảng trắng cuối khi so sánh bằng ='
        UNION ALL
        SELECT 'ERR_NON_ISO_DATE', N'2. Lỗi trước/sau làm sạch', N'Ngày dạng chuỗi không theo ISO',
               N'contracts.start_date/end_date, tickets.created_at/resolved_at',
               (SELECT COUNT(*) FROM stg.crm_contracts CROSS APPLY (VALUES (start_date), (end_date)) v(x) WHERE clean.fn_date_format(x) NOT IN ('ISO', 'EMPTY'))
             + (SELECT COUNT(*) FROM stg.ticket_support_tickets CROSS APPLY (VALUES (created_at), (resolved_at)) v(x) WHERE clean.fn_date_format(x) NOT IN ('ISO', 'EMPTY')),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE reason_code = 'INVALID_DATE'
                AND source_table IN (N'stg.crm_contracts', N'stg.ticket_support_tickets')),
               NULL, N'after (số dòng không parse được) = 0', N'Clean lưu kiểu DATE/DATETIME2; after = số dòng bị loại vì không đọc được ngày'
        UNION ALL
        SELECT 'ERR_NEGATIVE_AMOUNT', N'2. Lỗi trước/sau làm sạch', N'Amount hoá đơn âm', N'invoices.amount_usd',
               (SELECT COUNT(*) FROM stg.billing_invoices WHERE amount_usd < 0),
               (SELECT COUNT(*) FROM clean.invoices WHERE amount_usd < 0),
               NULL, N'after = 0', CONCAT(N'Đã đảo dấu ', (SELECT COUNT(*) FROM clean.invoices WHERE amount_source = 'SIGN_CORRECTED'), N' dòng')
        UNION ALL
        SELECT 'ERR_NULL_AMOUNT', N'2. Lỗi trước/sau làm sạch', N'Amount hoá đơn NULL', N'invoices.amount_usd',
               (SELECT COUNT(*) FROM stg.billing_invoices WHERE amount_usd IS NULL),
               (SELECT COUNT(*) FROM clean.invoices WHERE amount_usd IS NULL),
               NULL, N'after = 0',
               (SELECT N'Khôi phục: ' + STRING_AGG(CONCAT(amount_source, N'=', n), N', ')
                FROM (SELECT amount_source, COUNT(*) n FROM clean.invoices
                      WHERE amount_source IN ('FROM_PAYMENT', 'IMPUTED_PREV_INVOICE', 'IMPUTED_NEXT_INVOICE', 'IMPUTED_CONTRACT_PRICE')
                      GROUP BY amount_source) x)
        UNION ALL
        SELECT 'ERR_TOTAL_CHARGES_BLANK', N'2. Lỗi trước/sau làm sạch', N'TotalCharges rỗng (lỗi có sẵn trong dữ liệu gốc)', N'contracts.total_charges',
               (SELECT COUNT(*) FROM stg.crm_contracts WHERE NULLIF(LTRIM(RTRIM(total_charges)), N'') IS NULL),
               (SELECT COUNT(*) FROM clean.contracts WHERE total_charges IS NULL AND tenure_months > 0),
               NULL, N'after (rỗng mà tenure > 0) = 0', N'Rỗng chỉ hợp lệ với khách tenure = 0 (chưa phát sinh cước), giữ NULL';
        UPDATE #dq SET status = CASE WHEN value_after = 0 THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'2. Lỗi trước/sau làm sạch';

        /* 3. Đối chiếu khoá giữa CRM và Billing. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'KEY_ORPHAN_INVOICE', N'3. Đối chiếu CRM - Billing', N'Hoá đơn của customer_id không có trong CRM', N'invoices.customer_id',
               (SELECT COUNT(*) FROM stg.billing_invoices i
                WHERE NOT EXISTS (SELECT 1 FROM stg.crm_customers c WHERE LTRIM(RTRIM(c.customer_id)) = LTRIM(RTRIM(i.customer_id)))),
               (SELECT COUNT(*) FROM clean.invoices i WHERE NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = i.customer_id)),
               (SELECT COUNT(*) FROM clean.rejected_records WHERE source_table = N'stg.billing_invoices' AND reason_code = 'ORPHAN_CUSTOMER'),
               N'after = 0', NULL,
               (SELECT CONCAT(COUNT(DISTINCT LTRIM(RTRIM(i.customer_id))), N' customer_id mồ côi')
                FROM stg.billing_invoices i
                WHERE NOT EXISTS (SELECT 1 FROM stg.crm_customers c WHERE LTRIM(RTRIM(c.customer_id)) = LTRIM(RTRIM(i.customer_id))))
        UNION ALL
        -- Khách mà mọi kỳ cước đều rơi vào tháng không có hoá đơn nào (sự cố billing) thì thiếu hoá đơn là
        -- có giải thích (WARN); còn lại là FAIL.
        SELECT 'KEY_BILLED_CUSTOMER_NO_INVOICE', N'3. Đối chiếu CRM - Billing', N'Khách có kỳ cước theo CRM nhưng không có hoá đơn nào', N'contracts vs invoices',
               NULL, COUNT(*), NULL, N'after = 0; WARN nếu mọi kỳ cước của khách nằm trong tháng billing sự cố',
               CASE WHEN COUNT(*) = 0 THEN 'PASS' WHEN SUM(x.explained) = COUNT(*) THEN 'WARN' ELSE 'FAIL' END,
               CONCAT(SUM(x.explained), N'/', COUNT(*), N' khách chỉ có kỳ cước trong tháng không có hoá đơn nào')
        FROM clean.contracts k
        CROSS APPLY (SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM clean.invoices i2
                                                  WHERE i2.billing_month BETWEEN k.first_billing_month AND k.last_billing_month)
                                 THEN 1 ELSE 0 END AS explained) x
        WHERE k.first_billing_month IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM clean.invoices i WHERE i.customer_id = k.customer_id)
        UNION ALL
        SELECT 'KEY_INVOICE_OUTSIDE_CONTRACT', N'3. Đối chiếu CRM - Billing', N'Hoá đơn nằm ngoài vòng đời hợp đồng', N'invoices vs contracts',
               NULL, NULL,
               (SELECT COUNT(*) FROM clean.rejected_records WHERE source_table = N'stg.billing_invoices' AND reason_code = 'OUTSIDE_CONTRACT_PERIOD'),
               N'rejected = 0', NULL, NULL
        UNION ALL
        SELECT 'KEY_TENURE_VS_INVOICES', N'3. Đối chiếu CRM - Billing', N'tenure_months trong CRM khác số kỳ cước suy ra từ ngày hợp đồng', N'contracts',
               NULL,
               (SELECT COUNT(*) FROM clean.contracts WHERE first_billing_month IS NOT NULL
                AND DATEDIFF(MONTH, first_billing_month, last_billing_month) + 1 <> tenure_months),
               NULL, N'after = 0', NULL, NULL;
        UPDATE #dq SET status = CASE WHEN COALESCE(value_after, value_rejected) = 0 THEN 'PASS' ELSE 'FAIL' END
        WHERE check_group = N'3. Đối chiếu CRM - Billing' AND check_id NOT IN ('KEY_ORPHAN_INVOICE', 'KEY_BILLED_CUSTOMER_NO_INVOICE');
        UPDATE #dq SET status = CASE WHEN value_after = 0 AND value_rejected = value_before THEN 'PASS' ELSE 'FAIL' END
        WHERE check_id = 'KEY_ORPHAN_INVOICE';

        -- Tháng thiếu hoá đơn so với lịch cước của CRM: phát hiện sự cố billing mà không cần biết trước tháng nào.
        WITH expected AS (
            SELECT d.[date] AS billing_month, COUNT(*) AS customers
            FROM clean.contracts k
            JOIN mart.dim_date d ON d.is_month_start = 1 AND d.[date] BETWEEN k.first_billing_month AND k.last_billing_month
            GROUP BY d.[date]
        ), actual AS (
            SELECT billing_month, COUNT(*) AS invoices FROM clean.invoices GROUP BY billing_month
        ), gap AS (
            SELECT e.billing_month, e.customers, ISNULL(a.invoices, 0) AS invoices
            FROM expected e LEFT JOIN actual a ON a.billing_month = e.billing_month
            WHERE e.customers <> ISNULL(a.invoices, 0)
        )
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'KEY_MISSING_INVOICE_MONTH', N'3. Đối chiếu CRM - Billing', N'Khách-tháng có trong lịch cước CRM nhưng thiếu hoá đơn',
               N'contracts vs invoices', (SELECT SUM(customers) FROM expected), (SELECT ISNULL(SUM(customers - invoices), 0) FROM gap), NULL,
               N'after = 0; nếu thiếu cả tháng thì WARN (đã ước lượng ở fact_billing)',
               CASE WHEN NOT EXISTS (SELECT 1 FROM gap) THEN 'PASS'
                    WHEN NOT EXISTS (SELECT 1 FROM gap WHERE invoices > 0) THEN 'WARN' ELSE 'FAIL' END,
               (SELECT STRING_AGG(CONCAT(CONVERT(CHAR(7), billing_month, 120), N': thiếu ', customers - invoices, N'/', customers), N'; ') FROM gap);

        /* 4. Tổng tiền trước/sau. Chênh lệch stg -> clean phải giải thích được hoàn toàn bằng các bước sửa. */
        DECLARE @stg_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM stg.billing_invoices);
        DECLARE @clean_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM clean.invoices);
        DECLARE @sign_fix DECIMAL(18,2) = (SELECT ISNULL(SUM(2 * amount_usd), 0) FROM clean.invoices WHERE amount_source = 'SIGN_CORRECTED');
        DECLARE @null_fix DECIMAL(18,2) = (SELECT ISNULL(SUM(amount_usd), 0) FROM clean.invoices
                                           WHERE amount_source IN ('FROM_PAYMENT', 'IMPUTED_PREV_INVOICE', 'IMPUTED_NEXT_INVOICE', 'IMPUTED_CONTRACT_PRICE'));
        DECLARE @rejected_sum DECIMAL(18,2) = (SELECT ISNULL(SUM(s.amount_usd), 0) FROM stg.billing_invoices s
                                               JOIN clean.rejected_records r ON r.source_table = N'stg.billing_invoices' AND r.stg_row_id = s.stg_row_id);
        DECLARE @mart_sum DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM mart.fact_billing);
        DECLARE @mart_imputed DECIMAL(18,2) = (SELECT ISNULL(SUM(amount_usd), 0) FROM mart.fact_billing WHERE amount_source = 'IMPUTED_MISSING_INVOICE');
        DECLARE @pay_stg DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM stg.billing_payments);
        DECLARE @pay_clean DECIMAL(18,2) = (SELECT SUM(amount_usd) FROM clean.payments);
        DECLARE @pay_rejected DECIMAL(18,2) = (SELECT ISNULL(SUM(s.amount_usd), 0) FROM stg.billing_payments s
                                               JOIN clean.rejected_records r ON r.source_table = N'stg.billing_payments' AND r.stg_row_id = s.stg_row_id);

        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        VALUES
        ('AMT_INVOICE_STG_CLEAN', N'4. Tổng tiền', N'Tổng amount hoá đơn stg -> clean (USD)', N'invoices',
         @stg_sum, @clean_sum, @rejected_sum,
         N'clean = stg - rejected + 2 x |âm đã đảo| + NULL đã khôi phục',
         CASE WHEN ABS(@clean_sum - (@stg_sum - @rejected_sum + @sign_fix + @null_fix)) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
         CONCAT(N'+', @sign_fix, N' do đảo dấu; +', @null_fix, N' do khôi phục NULL; -', @rejected_sum, N' do loại bản ghi')),
        ('AMT_INVOICE_CLEAN_MART', N'4. Tổng tiền', N'Tổng amount clean.invoices -> mart.fact_billing (USD)', N'fact_billing',
         @clean_sum, @mart_sum, NULL,
         N'mart = clean + phần ước lượng cho tháng thiếu hoá đơn',
         CASE WHEN ABS(@mart_sum - (@clean_sum + @mart_imputed)) < 0.01 THEN 'PASS' ELSE 'FAIL' END,
         CONCAT(N'+', @mart_imputed, N' ước lượng cho khách-tháng thiếu hoá đơn')),
        ('AMT_PAYMENT_STG_CLEAN', N'4. Tổng tiền', N'Tổng thanh toán stg -> clean (USD)', N'payments',
         @pay_stg, @pay_clean, @pay_rejected, N'clean = stg - rejected',
         CASE WHEN ABS(@pay_clean - (@pay_stg - @pay_rejected)) < 0.01 THEN 'PASS' ELSE 'FAIL' END, NULL);

        -- Kiểm chứng giả định "âm là nhập nhầm dấu": sau khi đảo dấu, số tiền phải bằng số đã thanh toán.
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'AMT_SIGN_FIX_MATCHES_PAYMENT', N'4. Tổng tiền', N'Hoá đơn đã đảo dấu khớp với số tiền thanh toán', N'invoices vs payments',
               COUNT(*), SUM(CASE WHEN p.paid = i.amount_usd THEN 1 ELSE 0 END), NULL,
               N'after = before (với các hoá đơn đã có thanh toán)',
               CASE WHEN COUNT(*) = SUM(CASE WHEN p.paid = i.amount_usd THEN 1 ELSE 0 END) THEN 'PASS' ELSE 'WARN' END,
               N'Chỉ xét hoá đơn đã đảo dấu và đã có thanh toán'
        FROM clean.invoices i
        JOIN (SELECT invoice_id, SUM(amount_usd) paid FROM clean.payments GROUP BY invoice_id) p ON p.invoice_id = i.invoice_id
        WHERE i.amount_source = 'SIGN_CORRECTED';

        /* 5. Tính đầy đủ của dữ liệu tham chiếu. */
        INSERT INTO #dq (check_id, check_group, check_name, object_name, value_before, value_after, value_rejected, expected_rule, status, note)
        SELECT 'REF_FX_COVERAGE', N'5. Dữ liệu tham chiếu', N'Tháng có cước nhưng thiếu tỷ giá', N'fx_rates',
               NULL, COUNT(*), NULL, N'after = 0', CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END,
               (SELECT STRING_AGG(CONCAT(provider, N' (', granularity, N'): ', n, N' tháng'), N'; ')
                FROM (SELECT provider, granularity, COUNT(*) n FROM clean.fx_rates GROUP BY provider, granularity) x)
        FROM (SELECT DISTINCT billing_month FROM clean.invoices) i
        WHERE NOT EXISTS (SELECT 1 FROM clean.fx_rates f WHERE f.rate_month = i.billing_month)
        UNION ALL
        SELECT 'REF_TARGET_COVERAGE', N'5. Dữ liệu tham chiếu', N'Số tháng có chỉ tiêu trong cửa sổ phân tích', N'targets',
               24, COUNT(*), NULL, N'after = 24', CASE WHEN COUNT(*) = 24 THEN 'PASS' ELSE 'FAIL' END, NULL
        FROM clean.targets
        WHERE target_month BETWEEN dbo.fn_config_date('analysis_window_start') AND dbo.fn_config_date('snapshot_date');

        INSERT INTO mart.dq_check_results (batch_id, check_id, check_group, check_name, object_name, value_before,
            value_after, value_rejected, expected_rule, status, note, checked_at)
        SELECT @batch_id, check_id, check_group, check_name, object_name, value_before, value_after, value_rejected,
               expected_rule, status, note, SYSDATETIME()
        FROM #dq;

        SELECT @msg = STRING_AGG(CONCAT(status, N'=', n), N', ') FROM (SELECT status, COUNT(*) n FROM #dq GROUP BY status) x;
        DECLARE @n INT = (SELECT COUNT(*) FROM #dq);
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', NULL, @n, @msg;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', NULL, NULL, @msg;
        THROW;
    END CATCH
END
GO
