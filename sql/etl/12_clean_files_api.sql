/* stg -> clean cho các nguồn file và API: support tickets (CSV), targets (Excel), tỷ giá (API). */

CREATE OR ALTER PROCEDURE clean.usp_load_tickets @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_tickets', N'clean.tickets', N'TICKET_CSV', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        -- CSV không có khái niệm NULL: chuỗi rỗng ở resolved_at nghĩa là ticket chưa đóng.
        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.ticket_id)) AS ticket_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               clean.fn_parse_datetime(s.created_at) AS created_at,
               NULLIF(LTRIM(RTRIM(s.resolved_at)), N'') AS resolved_raw,
               clean.fn_parse_datetime(s.resolved_at) AS resolved_at,
               LTRIM(RTRIM(s.category)) AS category,
               LTRIM(RTRIM(s.priority)) AS priority,
               LTRIM(RTRIM(s.channel)) AS channel,
               LTRIM(RTRIM(s.status)) AS status,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #t
        FROM stg.ticket_support_tickets s;
        SET @read = @@ROWCOUNT;

        UPDATE #t SET reject_reason = 'MISSING_KEY', reject_detail = N'ticket_id hoặc customer_id rỗng'
        WHERE NULLIF(ticket_id, N'') IS NULL OR NULLIF(customer_id, N'') IS NULL;

        WITH ranked AS (
            SELECT reject_reason, reject_detail, ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY stg_row_id) AS rn
            FROM #t WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Trùng ticket_id' WHERE rn > 1;

        UPDATE t SET reject_reason = 'ORPHAN_CUSTOMER', reject_detail = N'customer_id không có trong CRM'
        FROM #t t
        WHERE t.reject_reason IS NULL AND NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = t.customer_id);

        UPDATE #t SET reject_reason = 'INVALID_DATE', reject_detail = N'Không parse được created_at/resolved_at hoặc resolved_at < created_at'
        WHERE reject_reason IS NULL
          AND (created_at IS NULL OR (resolved_raw IS NOT NULL AND resolved_at IS NULL) OR resolved_at < created_at);

        UPDATE #t SET reject_reason = 'INVALID_VALUE', reject_detail = N'Danh mục/độ ưu tiên/kênh/trạng thái ngoài danh mục hoặc trạng thái mâu thuẫn với resolved_at'
        WHERE reject_reason IS NULL
          AND (category NOT IN (N'Technical', N'Billing', N'Account', N'Service Request')
               OR priority NOT IN (N'High', N'Medium', N'Low')
               OR channel NOT IN (N'Phone', N'Chat', N'Email', N'Store')
               OR status NOT IN (N'Open', N'Closed')
               OR (status = N'Closed' AND resolved_at IS NULL)
               OR (status = N'Open' AND resolved_at IS NOT NULL));

        UPDATE t SET reject_reason = 'OUTSIDE_CONTRACT_PERIOD', reject_detail = N'Ticket tạo trước ngày ký hoặc sau ngày rời đi'
        FROM #t t JOIN clean.contracts k ON k.customer_id = t.customer_id
        WHERE t.reject_reason IS NULL
          AND (CAST(t.created_at AS DATE) < k.start_date OR CAST(t.created_at AS DATE) > k.end_date);

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, ticket_id, reject_reason, reject_detail FROM #t WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.tickets;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.ticket_support_tickets';
            INSERT INTO clean.tickets (ticket_id, customer_id, created_at, resolved_at, category, priority, channel,
                                       status, resolution_hours, stg_row_id)
            SELECT ticket_id, customer_id, created_at, resolved_at, category, priority, channel, status,
                   CAST(DATEDIFF(MINUTE, created_at, resolved_at) / 60.0 AS DECIMAL(10,2)), stg_row_id
            FROM #t WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.ticket_support_tickets';
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

CREATE OR ALTER PROCEDURE clean.usp_load_targets @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_targets', N'clean.targets', N'FINANCE_EXCEL', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        /*
          Nhận diện vai trò cột theo tên tiêu đề, không theo vị trí, vì Finance đặt tên khác nhau
          giữa các sheet ("Tháng " / "Thang", "Churn Rate mục tiêu (%)" / "Target churn %"...).
          Cột không nhận diện được sẽ làm cả dòng bị loại, thay vì đoán.
        */
        SELECT c.stg_row_id, c.sheet_name, c.excel_row, c.header_text, c.cell_value, c.cell_type,
               CASE WHEN LOWER(LTRIM(RTRIM(c.header_text))) LIKE N'th%ng%' OR LOWER(c.header_text) LIKE N'%month%' THEN 'month'
                    WHEN LOWER(c.header_text) LIKE N'%churn%' THEN 'churn'
                    WHEN LOWER(c.header_text) LIKE N'%mrr%' THEN 'mrr'
                    WHEN LOWER(c.header_text) LIKE N'%ghi ch%' OR LOWER(c.header_text) LIKE N'%note%' THEN 'note'
               END AS col_role
        INTO #cells
        FROM stg.finance_targets_cells c;

        SELECT sheet_name, excel_row,
               MIN(stg_row_id) AS stg_row_id,
               MAX(CASE WHEN col_role = 'month' THEN cell_value END) AS month_raw,
               MAX(CASE WHEN col_role = 'month' THEN cell_type END) AS month_type,
               MAX(CASE WHEN col_role = 'churn' THEN cell_value END) AS churn_raw,
               MAX(CASE WHEN col_role = 'churn' THEN header_text END) AS churn_header,
               MAX(CASE WHEN col_role = 'mrr' THEN cell_value END) AS mrr_raw,
               MAX(CASE WHEN col_role = 'note' THEN cell_value END) AS note,
               SUM(CASE WHEN col_role IS NULL THEN 1 ELSE 0 END) AS unmapped_cells,
               (SELECT STRING_AGG(CONCAT(x.header_text, N'=', x.cell_value), N' | ')
                FROM #cells x WHERE x.sheet_name = c.sheet_name AND x.excel_row = c.excel_row) AS raw_record
        INTO #r
        FROM #cells c
        GROUP BY sheet_name, excel_row;
        SET @read = @@ROWCOUNT;

        ALTER TABLE #r ADD target_month DATE, churn_rate DECIMAL(9,6), mrr DECIMAL(14,2),
                           reject_reason VARCHAR(50), reject_detail NVARCHAR(400);

        -- Sheet 2024 lưu tháng là ngày Excel; sheet 2025 lưu chuỗi 'Tmm/yyyy'.
        -- Churn rate nhập theo đơn vị % (1.39 = 1,39%): tiêu đề có ký hiệu % thì chia 100.
        UPDATE #r SET
            target_month = CASE
                WHEN month_type = 'datetime' THEN TRY_CONVERT(DATE, LEFT(month_raw, 10), 23)
                WHEN month_raw LIKE 'T[0-9][0-9]/[0-9][0-9][0-9][0-9]'
                    THEN TRY_CONVERT(DATE, CONCAT(RIGHT(month_raw, 4), SUBSTRING(month_raw, 2, 2), '01'), 112)
                ELSE CAST(clean.fn_parse_datetime(month_raw) AS DATE) END,
            churn_rate = TRY_CONVERT(DECIMAL(9,6), TRY_CONVERT(FLOAT, churn_raw)
                                     / CASE WHEN churn_header LIKE N'%[%]%' THEN 100.0 ELSE 1.0 END),
            mrr = TRY_CONVERT(DECIMAL(14,2), TRY_CONVERT(FLOAT, mrr_raw));

        UPDATE #r SET target_month = DATEFROMPARTS(YEAR(target_month), MONTH(target_month), 1) WHERE target_month IS NOT NULL;

        UPDATE #r SET reject_reason = 'UNMAPPED_COLUMN', reject_detail = N'Có cột không nhận diện được vai trò'
        WHERE unmapped_cells > 0;
        UPDATE #r SET reject_reason = 'INVALID_DATE', reject_detail = N'Không đọc được tháng'
        WHERE reject_reason IS NULL AND target_month IS NULL;
        UPDATE #r SET reject_reason = 'INVALID_VALUE', reject_detail = N'Churn target ngoài (0, 1) hoặc MRR target <= 0'
        WHERE reject_reason IS NULL AND (churn_rate IS NULL OR churn_rate <= 0 OR churn_rate >= 1 OR mrr IS NULL OR mrr <= 0);

        WITH ranked AS (
            SELECT reject_reason, reject_detail,
                   ROW_NUMBER() OVER (PARTITION BY target_month ORDER BY sheet_name DESC, excel_row DESC) AS rn
            FROM #r WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Tháng xuất hiện nhiều lần' WHERE rn > 1;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail, raw_record)
        SELECT stg_row_id, CONCAT(sheet_name, N'!row ', excel_row), reject_reason, reject_detail, raw_record
        FROM #r WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.targets;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.finance_targets_cells';
            INSERT INTO clean.targets (target_month, churn_rate_target, mrr_target_usd, note, sheet_name, excel_row)
            SELECT target_month, churn_rate, mrr, note, sheet_name, excel_row FROM #r WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.finance_targets_cells';
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

CREATE OR ALTER PROCEDURE clean.usp_load_fx_rates @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_fx_rates', N'clean.fx_rates', N'FX_API', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id, s.rate_month,
               TRY_CONVERT(DATE, CONCAT(LTRIM(RTRIM(s.rate_month)), '-01'), 23) AS rate_month_date,
               TRY_CONVERT(DATE, s.rate_date, 23) AS rate_date,
               TRY_CONVERT(DECIMAL(18,4), TRY_CONVERT(FLOAT, s.usd_vnd)) AS usd_vnd,
               LTRIM(RTRIM(s.provider)) AS provider,
               LTRIM(RTRIM(s.granularity)) AS granularity,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #f
        FROM stg.api_fx_rates s;
        SET @read = @@ROWCOUNT;

        UPDATE #f SET reject_reason = 'INVALID_DATE', reject_detail = N'Không đọc được tháng hoặc ngày tỷ giá'
        WHERE rate_month_date IS NULL OR rate_date IS NULL;
        -- Chặn số vô lý (lỗi đơn vị, đảo cặp tiền VND->USD) trước khi nhân vào doanh thu.
        UPDATE #f SET reject_reason = 'INVALID_VALUE', reject_detail = N'Tỷ giá USD/VND ngoài khoảng hợp lý 10.000 - 50.000'
        WHERE reject_reason IS NULL AND (usd_vnd IS NULL OR usd_vnd NOT BETWEEN 10000 AND 50000);
        WITH ranked AS (
            SELECT reject_reason, reject_detail, ROW_NUMBER() OVER (PARTITION BY rate_month_date ORDER BY stg_row_id DESC) AS rn
            FROM #f WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Tháng có nhiều tỷ giá' WHERE rn > 1;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, rate_month, reject_reason, reject_detail FROM #f WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.fx_rates;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.api_fx_rates';
            INSERT INTO clean.fx_rates (rate_month, usd_vnd, rate_date, provider, granularity)
            SELECT rate_month_date, usd_vnd, rate_date, provider, granularity FROM #f WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.api_fx_rates';
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
