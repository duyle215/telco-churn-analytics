/*
  clean -> mart: dimensions.
  MERGE as SCD type 1 (overwrite attributes, no history) because the sources only hold the current state.
  Surrogate keys never change between runs; rows are only updated when an attribute really changes
  (compared with EXCEPT so NULLs are handled correctly).
*/

CREATE OR ALTER PROCEDURE mart.usp_load_dim_date @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @written INT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_dim_date', N'mart.dim_date', NULL, @log_id OUTPUT;
    BEGIN TRY
        DECLARE @snapshot DATE = dbo.fn_config_date('snapshot_date');
        DECLARE @window_start DATE = dbo.fn_config_date('analysis_window_start');
        IF @snapshot IS NULL OR @window_start IS NULL THROW 50003, N'Missing etl_config.snapshot_date/analysis_window_start', 1;
        -- The calendar covers whole years: from the earliest signup year to the end of the snapshot year.
        DECLARE @start DATE = DATEFROMPARTS(YEAR((SELECT MIN(start_date) FROM clean.contracts)), 1, 1);
        DECLARE @end DATE = DATEFROMPARTS(YEAR(@snapshot), 12, 31);

        WITH n AS (
            SELECT TOP (DATEDIFF(DAY, @start, @end) + 1) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
            FROM sys.all_objects a CROSS JOIN sys.all_objects b
        ), d AS (
            SELECT DATEADD(DAY, i, @start) AS dt FROM n
        ), s AS (
            SELECT YEAR(dt) * 10000 + MONTH(dt) * 100 + DAY(dt) AS date_key,
                   dt AS [date],
                   YEAR(dt) AS [year],
                   DATEPART(QUARTER, dt) AS quarter,
                   CONCAT('Q', DATEPART(QUARTER, dt)) AS quarter_label,
                   CONCAT(YEAR(dt), '-Q', DATEPART(QUARTER, dt)) AS year_quarter,
                   MONTH(dt) AS [month],
                   -- CHOOSE instead of DATENAME so the result does not depend on the session language.
                   CHOOSE(MONTH(dt), 'January', 'February', 'March', 'April', 'May', 'June', 'July',
                          'August', 'September', 'October', 'November', 'December') AS month_name,
                   CHOOSE(MONTH(dt), 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec') AS month_short,
                   CONVERT(CHAR(7), dt, 120) AS year_month,
                   YEAR(dt) * 100 + MONTH(dt) AS year_month_key,
                   DATEFROMPARTS(YEAR(dt), MONTH(dt), 1) AS month_start_date,
                   EOMONTH(dt) AS month_end_date,
                   DATEDIFF(MONTH, @start, dt) AS month_index,
                   DAY(dt) AS day_of_month,
                   -- 1900-01-01 was a Monday, so this formula does not depend on SET DATEFIRST.
                   DATEDIFF(DAY, '19000101', dt) % 7 + 1 AS day_of_week,
                   CHOOSE(DATEDIFF(DAY, '19000101', dt) % 7 + 1, 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
                          'Friday', 'Saturday', 'Sunday') AS day_name,
                   DATEPART(ISO_WEEK, dt) AS iso_week,
                   CASE WHEN DATEDIFF(DAY, '19000101', dt) % 7 >= 5 THEN 1 ELSE 0 END AS is_weekend,
                   CASE WHEN DAY(dt) = 1 THEN 1 ELSE 0 END AS is_month_start,
                   CASE WHEN dt BETWEEN @window_start AND @snapshot THEN 1 ELSE 0 END AS is_analysis_window,
                   CASE WHEN YEAR(dt) = YEAR(@snapshot) AND MONTH(dt) = MONTH(@snapshot) THEN 1 ELSE 0 END AS is_snapshot_month
            FROM d
        )
        MERGE mart.dim_date AS t
        USING s ON t.date_key = s.date_key
        WHEN MATCHED AND (t.is_analysis_window <> s.is_analysis_window OR t.is_snapshot_month <> s.is_snapshot_month
                          OR t.month_index <> s.month_index) THEN
            UPDATE SET is_analysis_window = s.is_analysis_window, is_snapshot_month = s.is_snapshot_month,
                       month_index = s.month_index
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (date_key, [date], [year], quarter, quarter_label, year_quarter, [month], month_name, month_short,
                    year_month, year_month_key, month_start_date, month_end_date, month_index, day_of_month,
                    day_of_week, day_name, iso_week, is_weekend, is_month_start, is_analysis_window, is_snapshot_month)
            VALUES (s.date_key, s.[date], s.[year], s.quarter, s.quarter_label, s.year_quarter, s.[month], s.month_name,
                    s.month_short, s.year_month, s.year_month_key, s.month_start_date, s.month_end_date, s.month_index,
                    s.day_of_month, s.day_of_week, s.day_name, s.iso_week, s.is_weekend, s.is_month_start,
                    s.is_analysis_window, s.is_snapshot_month);
        SET @written = @@ROWCOUNT;

        SET @msg = CONCAT(N'range ', @start, N'..', @end, N'; merged rows ', @written);
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', NULL, @written, @msg;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', NULL, NULL, @msg;
        THROW;
    END CATCH
END
GO

CREATE OR ALTER PROCEDURE mart.usp_load_dimensions @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON; SET XACT_ABORT ON;
    DECLARE @log_id BIGINT, @written INT = 0, @n INT, @msg NVARCHAR(4000) = N'';
    EXEC dbo.usp_etl_log_start @batch_id, 'mart', N'mart.usp_load_dimensions', N'mart.dim_customer/contract/payment_method/service', NULL, @log_id OUTPUT;
    BEGIN TRY
        BEGIN TRAN;

        /* dim_customer: demographics + lifecycle. 12-month tenure bands are the usual split in telecom. */
        WITH s AS (
            SELECT c.customer_id, c.gender,
                   CASE c.is_senior_citizen WHEN 1 THEN N'Yes' ELSE N'No' END AS senior_citizen,
                   CASE c.has_partner WHEN 1 THEN N'Yes' ELSE N'No' END AS partner,
                   CASE c.has_dependents WHEN 1 THEN N'Yes' ELSE N'No' END AS dependents,
                   k.start_date AS signup_date,
                   DATEFROMPARTS(YEAR(k.start_date), MONTH(k.start_date), 1) AS signup_month,
                   k.tenure_months,
                   CASE WHEN k.tenure_months <= 12 THEN N'0-12 months' WHEN k.tenure_months <= 24 THEN N'13-24 months'
                        WHEN k.tenure_months <= 36 THEN N'25-36 months' WHEN k.tenure_months <= 48 THEN N'37-48 months'
                        WHEN k.tenure_months <= 60 THEN N'49-60 months' WHEN k.tenure_months IS NOT NULL THEN N'61-72 months' END AS tenure_group,
                   CASE WHEN k.tenure_months <= 12 THEN 1 WHEN k.tenure_months <= 24 THEN 2 WHEN k.tenure_months <= 36 THEN 3
                        WHEN k.tenure_months <= 48 THEN 4 WHEN k.tenure_months <= 60 THEN 5 WHEN k.tenure_months IS NOT NULL THEN 6 END AS tenure_group_order,
                   CASE WHEN k.customer_id IS NULL THEN N'Unknown' WHEN k.is_churned = 1 THEN N'Churned'
                        WHEN k.tenure_months = 0 THEN N'New (not billed)' ELSE N'Active' END AS customer_status,
                   k.end_date AS churn_date, k.churn_month, k.first_billing_month, k.last_billing_month,
                   k.monthly_charges AS current_monthly_charges
            FROM clean.customers c
            LEFT JOIN clean.contracts k ON k.customer_id = c.customer_id
        )
        MERGE mart.dim_customer AS t
        USING s ON t.customer_id = s.customer_id
        WHEN MATCHED AND EXISTS (
            SELECT s.gender, s.senior_citizen, s.partner, s.dependents, s.signup_date, s.signup_month, s.tenure_months,
                   s.tenure_group, s.tenure_group_order, s.customer_status, s.churn_date, s.churn_month,
                   s.first_billing_month, s.last_billing_month, s.current_monthly_charges
            EXCEPT
            SELECT t.gender, t.senior_citizen, t.partner, t.dependents, t.signup_date, t.signup_month, t.tenure_months,
                   t.tenure_group, t.tenure_group_order, t.customer_status, t.churn_date, t.churn_month,
                   t.first_billing_month, t.last_billing_month, t.current_monthly_charges) THEN
            UPDATE SET gender = s.gender, senior_citizen = s.senior_citizen, partner = s.partner, dependents = s.dependents,
                       signup_date = s.signup_date, signup_month = s.signup_month, tenure_months = s.tenure_months,
                       tenure_group = s.tenure_group, tenure_group_order = s.tenure_group_order,
                       customer_status = s.customer_status, churn_date = s.churn_date, churn_month = s.churn_month,
                       first_billing_month = s.first_billing_month, last_billing_month = s.last_billing_month,
                       current_monthly_charges = s.current_monthly_charges
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (customer_id, gender, senior_citizen, partner, dependents, signup_date, signup_month, tenure_months,
                    tenure_group, tenure_group_order, customer_status, churn_date, churn_month, first_billing_month,
                    last_billing_month, current_monthly_charges)
            VALUES (s.customer_id, s.gender, s.senior_citizen, s.partner, s.dependents, s.signup_date, s.signup_month,
                    s.tenure_months, s.tenure_group, s.tenure_group_order, s.customer_status, s.churn_date, s.churn_month,
                    s.first_billing_month, s.last_billing_month, s.current_monthly_charges);
        SET @n = @@ROWCOUNT; SET @written += @n; SET @msg += CONCAT(N'dim_customer ', @n, N'; ');

        WITH s AS (
            SELECT DISTINCT contract_type, CASE is_paperless_billing WHEN 1 THEN N'Yes' ELSE N'No' END AS paperless_billing,
                   CASE contract_type WHEN N'Month-to-month' THEN 1 WHEN N'One year' THEN 12 ELSE 24 END AS contract_term_months,
                   CASE contract_type WHEN N'Month-to-month' THEN 1 WHEN N'One year' THEN 2 ELSE 3 END AS contract_sort
            FROM clean.contracts
        )
        MERGE mart.dim_contract AS t
        USING s ON t.contract_type = s.contract_type AND t.paperless_billing = s.paperless_billing
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (contract_type, paperless_billing, contract_term_months, contract_sort)
            VALUES (s.contract_type, s.paperless_billing, s.contract_term_months, s.contract_sort);
        SET @n = @@ROWCOUNT; SET @written += @n; SET @msg += CONCAT(N'dim_contract ', @n, N'; ');

        WITH s AS (
            SELECT DISTINCT payment_method,
                   CASE WHEN payment_method LIKE N'%(automatic)' THEN N'Automatic' ELSE N'Manual' END AS payment_type,
                   CASE WHEN payment_method LIKE N'%(automatic)' THEN 1 ELSE 0 END AS is_automatic
            FROM clean.contracts
        )
        MERGE mart.dim_payment_method AS t
        USING s ON t.payment_method = s.payment_method
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (payment_method, payment_type, is_automatic) VALUES (s.payment_method, s.payment_type, s.is_automatic);
        SET @n = @@ROWCOUNT; SET @written += @n; SET @msg += CONCAT(N'dim_payment_method ', @n, N'; ');

        WITH combos AS (
            SELECT DISTINCT phone_service, multiple_lines, internet_service, online_security, online_backup,
                   device_protection, tech_support, streaming_tv, streaming_movies
            FROM clean.services
        ), s AS (
            SELECT c.*,
                   (SELECT COUNT(*) FROM (VALUES (c.online_security), (c.online_backup), (c.device_protection),
                                                 (c.tech_support), (c.streaming_tv), (c.streaming_movies)) a(v)
                    WHERE a.v = N'Yes') AS addon_count
            FROM combos c
        )
        MERGE mart.dim_service AS t
        USING s ON t.phone_service = s.phone_service AND t.multiple_lines = s.multiple_lines
               AND t.internet_service = s.internet_service AND t.online_security = s.online_security
               AND t.online_backup = s.online_backup AND t.device_protection = s.device_protection
               AND t.tech_support = s.tech_support AND t.streaming_tv = s.streaming_tv
               AND t.streaming_movies = s.streaming_movies
        WHEN NOT MATCHED BY TARGET THEN
            INSERT (phone_service, multiple_lines, internet_service, online_security, online_backup, device_protection,
                    tech_support, streaming_tv, streaming_movies, addon_count, has_streaming, internet_sort)
            VALUES (s.phone_service, s.multiple_lines, s.internet_service, s.online_security, s.online_backup,
                    s.device_protection, s.tech_support, s.streaming_tv, s.streaming_movies, s.addon_count,
                    CASE WHEN s.streaming_tv = N'Yes' OR s.streaming_movies = N'Yes' THEN N'Yes' ELSE N'No' END,
                    CASE s.internet_service WHEN N'Fiber optic' THEN 1 WHEN N'DSL' THEN 2 ELSE 3 END);
        SET @n = @@ROWCOUNT; SET @written += @n; SET @msg += CONCAT(N'dim_service ', @n);

        COMMIT;
        SET @msg = N'merged: ' + @msg;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', NULL, @written, @msg;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', NULL, NULL, @msg;
        THROW;
    END CATCH
END
GO
