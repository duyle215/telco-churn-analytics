/* Điều phối toàn bộ ETL stg -> clean -> mart -> data quality. Gọi: EXEC dbo.usp_run_etl; */

CREATE OR ALTER PROCEDURE clean.usp_run_all @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    -- Thứ tự quan trọng: CRM trước để Billing/Ticket đối chiếu khoá, invoices trước payments.
    EXEC clean.usp_load_customers @batch_id;
    EXEC clean.usp_load_contracts @batch_id;
    EXEC clean.usp_load_services @batch_id;
    EXEC clean.usp_load_invoices @batch_id;
    EXEC clean.usp_load_payments @batch_id;
    EXEC clean.usp_load_tickets @batch_id;
    EXEC clean.usp_load_targets @batch_id;
    EXEC clean.usp_load_fx_rates @batch_id;
END
GO

CREATE OR ALTER PROCEDURE mart.usp_run_all @batch_id UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;
    EXEC mart.usp_load_dim_date @batch_id;
    EXEC mart.usp_load_dimensions @batch_id;
    EXEC mart.usp_load_fact_billing @batch_id;
    EXEC mart.usp_load_fact_tickets @batch_id;
    EXEC mart.usp_load_fact_target @batch_id;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_run_etl @batch_id UNIQUEIDENTIFIER = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @batch_id = COALESCE(@batch_id, NEWID());
    DECLARE @log_id BIGINT, @msg NVARCHAR(4000);
    EXEC dbo.usp_etl_log_start @batch_id, 'pipeline', N'dbo.usp_run_etl', NULL, NULL, @log_id OUTPUT;
    BEGIN TRY
        EXEC clean.usp_run_all @batch_id;
        EXEC mart.usp_run_all @batch_id;
        EXEC dbo.usp_run_dq_checks @batch_id;
        SELECT @msg = CONCAT(N'DQ: ', STRING_AGG(CONCAT(status, N'=', n), N', '))
        FROM (SELECT status, COUNT(*) n FROM mart.dq_check_results WHERE batch_id = @batch_id GROUP BY status) x;
        EXEC dbo.usp_etl_log_end @log_id, 'SUCCESS', NULL, NULL, @msg;
    END TRY
    BEGIN CATCH
        SET @msg = ERROR_MESSAGE();
        EXEC dbo.usp_etl_log_end @log_id, 'FAILED', NULL, NULL, @msg;
        THROW;
    END CATCH
    SELECT @batch_id AS batch_id;
END
GO
