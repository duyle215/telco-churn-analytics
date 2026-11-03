/*
  stg -> clean cho CRM: customers, contracts, services.
  Khuôn chung của mỗi proc:
    1. Đọc stg vào bảng tạm, chuẩn hoá (TRIM, đổi kiểu, gom biến thể Yes/No).
    2. Đánh dấu lý do loại theo thứ tự ưu tiên; mỗi dòng chỉ mang 1 lý do đầu tiên gặp.
    3. Trong 1 transaction: TRUNCATE bảng clean + xoá rejected cũ của nguồn này, rồi nạp lại.
       Nhờ vậy chạy lại bao nhiêu lần cũng ra cùng kết quả (idempotent).
    4. Ghi etl_log: rows_read = số dòng stg, rows_written = số dòng clean, message = thống kê bị loại.
*/

CREATE OR ALTER PROCEDURE clean.usp_load_customers @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_customers', N'clean.customers', N'CRM', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               CASE UPPER(LTRIM(RTRIM(s.gender))) WHEN 'MALE' THEN N'Male' WHEN 'FEMALE' THEN N'Female' END AS gender,
               CAST(CASE s.senior_citizen WHEN 1 THEN 1 WHEN 0 THEN 0 END AS BIT) AS is_senior_citizen,
               clean.fn_yes_no_to_bit(s.partner) AS has_partner,
               clean.fn_yes_no_to_bit(s.dependents) AS has_dependents,
               s.created_at, s.updated_at,
               CAST(NULL AS INT) AS rn,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #c
        FROM stg.crm_customers s;
        SET @read = @@ROWCOUNT;

        UPDATE #c SET reject_reason = 'MISSING_KEY', reject_detail = N'customer_id rỗng'
        WHERE NULLIF(customer_id, N'') IS NULL;

        UPDATE #c SET reject_reason = 'INVALID_VALUE',
                      reject_detail = N'Không nhận diện được giá trị gender/senior_citizen/partner/dependents'
        WHERE reject_reason IS NULL
          AND (gender IS NULL OR is_senior_citizen IS NULL OR has_partner IS NULL OR has_dependents IS NULL);

        -- CRM cũ không có khoá chính nên một khách có thể bị nhập nhiều lần. Giữ phiên bản
        -- updated_at mới nhất (thông tin cập nhật sau cùng), các bản còn lại đưa vào rejected.
        -- Phải TRIM trước khi xếp hạng: 'ABC ' và 'ABC' là cùng một khách.
        WITH ranked AS (
            SELECT rn, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY updated_at DESC, stg_row_id DESC) AS new_rn
            FROM #c WHERE reject_reason IS NULL
        )
        UPDATE ranked SET rn = new_rn;

        UPDATE d
        SET reject_reason = 'DUPLICATE_KEY',
            reject_detail = CASE
                WHEN d.gender = k.gender AND d.is_senior_citizen = k.is_senior_citizen
                     AND d.has_partner = k.has_partner AND d.has_dependents = k.has_dependents
                THEN CONCAT(N'Trùng hoàn toàn với bản được giữ (stg_row_id ', k.stg_row_id, N')')
                ELSE CONCAT(N'Phiên bản cũ (updated_at ', CONVERT(NVARCHAR(19), d.updated_at, 120),
                            N'), giữ bản mới hơn stg_row_id ', k.stg_row_id)
            END
        FROM #c d
        JOIN #c k ON k.customer_id = d.customer_id AND k.rn = 1
        WHERE d.rn > 1;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, customer_id, reject_reason, reject_detail FROM #c WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.customers;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.crm_customers';
            INSERT INTO clean.customers (customer_id, gender, is_senior_citizen, has_partner, has_dependents,
                                         created_at, updated_at, stg_row_id)
            SELECT customer_id, gender, is_senior_citizen, has_partner, has_dependents, created_at, updated_at, stg_row_id
            FROM #c WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.crm_customers';
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

CREATE OR ALTER PROCEDURE clean.usp_load_contracts @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_contracts', N'clean.contracts', N'CRM', @log_id OUTPUT;
    BEGIN TRY
        DECLARE @snapshot DATE = dbo.fn_config_date('snapshot_date');
        IF @snapshot IS NULL THROW 50002, N'Thiếu etl_config.snapshot_date', 1;
        DECLARE @snapshot_month DATE = DATEFROMPARTS(YEAR(@snapshot), MONTH(@snapshot), 1);

        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.contract_id)) AS contract_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               CASE UPPER(LTRIM(RTRIM(s.contract_type)))
                    WHEN 'MONTH-TO-MONTH' THEN N'Month-to-month' WHEN 'ONE YEAR' THEN N'One year'
                    WHEN 'TWO YEAR' THEN N'Two year' END AS contract_type,
               clean.fn_yes_no_to_bit(s.paperless_billing) AS is_paperless_billing,
               CASE UPPER(LTRIM(RTRIM(s.payment_method)))
                    WHEN 'ELECTRONIC CHECK' THEN N'Electronic check' WHEN 'MAILED CHECK' THEN N'Mailed check'
                    WHEN 'BANK TRANSFER (AUTOMATIC)' THEN N'Bank transfer (automatic)'
                    WHEN 'CREDIT CARD (AUTOMATIC)' THEN N'Credit card (automatic)' END AS payment_method,
               s.monthly_charges,
               NULLIF(LTRIM(RTRIM(s.total_charges)), N'') AS total_charges_raw,
               TRY_CONVERT(DECIMAL(12,2), NULLIF(LTRIM(RTRIM(s.total_charges)), N'')) AS total_charges,
               s.tenure_months,
               CAST(clean.fn_parse_datetime(s.start_date) AS DATE) AS start_date,
               NULLIF(LTRIM(RTRIM(s.end_date)), N'') AS end_date_raw,
               CAST(clean.fn_parse_datetime(s.end_date) AS DATE) AS end_date,
               LTRIM(RTRIM(s.contract_status)) AS contract_status,
               clean.fn_yes_no_to_bit(s.churn_flag) AS is_churned,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #k
        FROM stg.crm_contracts s;
        SET @read = @@ROWCOUNT;

        UPDATE #k SET reject_reason = 'MISSING_KEY', reject_detail = N'contract_id hoặc customer_id rỗng'
        WHERE NULLIF(contract_id, N'') IS NULL OR NULLIF(customer_id, N'') IS NULL;

        UPDATE k SET reject_reason = 'ORPHAN_CUSTOMER', reject_detail = N'customer_id không có trong clean.customers'
        FROM #k k
        WHERE k.reject_reason IS NULL AND NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = k.customer_id);

        UPDATE #k SET reject_reason = 'INVALID_VALUE',
                      reject_detail = N'Giá trị không hợp lệ ở contract_type/payment_method/cờ Yes-No/monthly_charges/tenure/total_charges/status'
        WHERE reject_reason IS NULL
          AND (contract_type IS NULL OR payment_method IS NULL OR is_paperless_billing IS NULL OR is_churned IS NULL
               OR monthly_charges IS NULL OR monthly_charges <= 0 OR tenure_months IS NULL OR tenure_months < 0
               OR (total_charges_raw IS NOT NULL AND total_charges IS NULL)
               OR contract_status NOT IN (N'Active', N'Terminated'));

        UPDATE #k SET reject_reason = 'INVALID_DATE', reject_detail = N'Không parse được start_date/end_date hoặc end_date < start_date'
        WHERE reject_reason IS NULL
          AND (start_date IS NULL OR (end_date_raw IS NOT NULL AND end_date IS NULL) OR end_date < start_date);

        -- Ba nguồn thông tin về việc rời đi (cờ churn, trạng thái, ngày kết thúc) phải khớp nhau;
        -- nếu lệch thì không biết tin cái nào, nên loại ra để người nghiệp vụ xem lại.
        UPDATE #k SET reject_reason = 'INCONSISTENT_STATUS',
                      reject_detail = N'churn_flag, contract_status và end_date mâu thuẫn nhau'
        WHERE reject_reason IS NULL
          AND ((is_churned = 1 AND (end_date IS NULL OR contract_status <> N'Terminated'))
            OR (is_churned = 0 AND (end_date IS NOT NULL OR contract_status <> N'Active')));

        WITH ranked AS (
            SELECT reject_reason, reject_detail,
                   ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY start_date DESC, stg_row_id DESC) AS rn_customer,
                   ROW_NUMBER() OVER (PARTITION BY contract_id ORDER BY stg_row_id DESC) AS rn_contract
            FROM #k WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Trùng contract_id hoặc khách có nhiều hợp đồng'
        WHERE rn_customer > 1 OR rn_contract > 1;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, contract_id, reject_reason, reject_detail FROM #k WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.contracts;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.crm_contracts';
            INSERT INTO clean.contracts (contract_id, customer_id, contract_type, is_paperless_billing, payment_method,
                                         monthly_charges, total_charges, tenure_months, start_date, end_date,
                                         contract_status, is_churned, churn_month, first_billing_month,
                                         last_billing_month, stg_row_id)
            SELECT contract_id, customer_id, contract_type, is_paperless_billing, payment_method,
                   monthly_charges, total_charges, tenure_months, start_date, end_date,
                   contract_status, is_churned,
                   x.churn_month,
                   -- Tính cước sau: kỳ đầu là tháng kế tiếp tháng ký; khách tenure = 0 chưa có kỳ nào.
                   CASE WHEN tenure_months > 0 THEN DATEADD(MONTH, 1, DATEFROMPARTS(YEAR(start_date), MONTH(start_date), 1)) END,
                   CASE WHEN tenure_months > 0 THEN COALESCE(x.churn_month, @snapshot_month) END,
                   stg_row_id
            FROM #k
            CROSS APPLY (SELECT CASE WHEN end_date IS NOT NULL THEN DATEFROMPARTS(YEAR(end_date), MONTH(end_date), 1) END AS churn_month) x
            WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.crm_contracts';
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

CREATE OR ALTER PROCEDURE clean.usp_load_services @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @read INT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'clean', N'clean.usp_load_services', N'clean.services', N'CRM', @log_id OUTPUT;
    BEGIN TRY
        CREATE TABLE #reject (stg_row_id BIGINT, business_key NVARCHAR(100), reason_code VARCHAR(50),
                              reason_detail NVARCHAR(400), raw_record NVARCHAR(MAX));

        SELECT s.stg_row_id,
               LTRIM(RTRIM(s.customer_id)) AS customer_id,
               clean.fn_normalize_service_value(s.phone_service) AS phone_service,
               clean.fn_normalize_service_value(s.multiple_lines) AS multiple_lines,
               clean.fn_normalize_service_value(s.internet_service) AS internet_service,
               clean.fn_normalize_service_value(s.online_security) AS online_security,
               clean.fn_normalize_service_value(s.online_backup) AS online_backup,
               clean.fn_normalize_service_value(s.device_protection) AS device_protection,
               clean.fn_normalize_service_value(s.tech_support) AS tech_support,
               clean.fn_normalize_service_value(s.streaming_tv) AS streaming_tv,
               clean.fn_normalize_service_value(s.streaming_movies) AS streaming_movies,
               CAST(NULL AS VARCHAR(50)) AS reject_reason,
               CAST(NULL AS NVARCHAR(400)) AS reject_detail
        INTO #s
        FROM stg.crm_services s;
        SET @read = @@ROWCOUNT;

        UPDATE #s SET reject_reason = 'MISSING_KEY', reject_detail = N'customer_id rỗng'
        WHERE NULLIF(customer_id, N'') IS NULL;

        UPDATE s SET reject_reason = 'ORPHAN_CUSTOMER', reject_detail = N'customer_id không có trong clean.customers'
        FROM #s s
        WHERE s.reject_reason IS NULL AND NOT EXISTS (SELECT 1 FROM clean.customers c WHERE c.customer_id = s.customer_id);

        -- Mỗi cột chỉ nhận đúng bộ giá trị của nó, và các cột phụ thuộc phải khớp với dịch vụ gốc
        -- (không có internet thì add-on phải là 'No internet service').
        UPDATE #s SET reject_reason = 'INVALID_VALUE', reject_detail = N'Giá trị dịch vụ ngoài danh mục hoặc mâu thuẫn giữa các cột'
        WHERE reject_reason IS NULL AND (
               phone_service NOT IN (N'Yes', N'No') OR phone_service IS NULL
            OR multiple_lines NOT IN (N'Yes', N'No', N'No phone service') OR multiple_lines IS NULL
            OR internet_service NOT IN (N'DSL', N'Fiber optic', N'No') OR internet_service IS NULL
            OR (phone_service = N'No' AND multiple_lines <> N'No phone service')
            OR (phone_service = N'Yes' AND multiple_lines = N'No phone service')
            OR EXISTS (SELECT 1 FROM (VALUES (online_security), (online_backup), (device_protection),
                                             (tech_support), (streaming_tv), (streaming_movies)) a(v)
                       WHERE a.v IS NULL OR a.v NOT IN (N'Yes', N'No', N'No internet service')
                          OR (internet_service = N'No' AND a.v <> N'No internet service')
                          OR (internet_service <> N'No' AND a.v = N'No internet service')));

        WITH ranked AS (
            SELECT reject_reason, reject_detail, ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY stg_row_id DESC) AS rn
            FROM #s WHERE reject_reason IS NULL
        )
        UPDATE ranked SET reject_reason = 'DUPLICATE_KEY', reject_detail = N'Khách có nhiều dòng dịch vụ'
        WHERE rn > 1;

        INSERT INTO #reject (stg_row_id, business_key, reason_code, reason_detail)
        SELECT stg_row_id, customer_id, reject_reason, reject_detail FROM #s WHERE reject_reason IS NOT NULL;

        BEGIN TRAN;
            TRUNCATE TABLE clean.services;
            DELETE FROM clean.rejected_records WHERE source_table = N'stg.crm_services';
            INSERT INTO clean.services (customer_id, phone_service, multiple_lines, internet_service, online_security,
                                        online_backup, device_protection, tech_support, streaming_tv, streaming_movies, stg_row_id)
            SELECT customer_id, phone_service, multiple_lines, internet_service, online_security,
                   online_backup, device_protection, tech_support, streaming_tv, streaming_movies, stg_row_id
            FROM #s WHERE reject_reason IS NULL;
            SET @written = @@ROWCOUNT;
            EXEC clean.usp_write_rejects @batch_id, N'stg.crm_services';
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
