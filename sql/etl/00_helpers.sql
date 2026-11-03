/* Hàm và thủ tục dùng chung cho ETL. */

CREATE OR ALTER PROCEDURE dbo.usp_etl_log_start
    @batch_id UNIQUEIDENTIFIER, @layer VARCHAR(10), @step_name NVARCHAR(100),
    @object_name NVARCHAR(128) = NULL, @source_system NVARCHAR(30) = NULL, @log_id BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.etl_log (batch_id, layer, step_name, object_name, source_system, status, started_at)
    VALUES (@batch_id, @layer, @step_name, @object_name, @source_system, 'RUNNING', SYSDATETIME());
    SET @log_id = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_etl_log_end
    @log_id BIGINT, @status VARCHAR(10), @rows_read INT = NULL, @rows_written INT = NULL,
    @message NVARCHAR(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.etl_log
    SET status = @status, rows_read = @rows_read, rows_written = @rows_written,
        message = @message, finished_at = SYSDATETIME()
    WHERE log_id = @log_id;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_config_date (@key VARCHAR(50))
RETURNS DATE
AS
BEGIN
    RETURN (SELECT TRY_CONVERT(DATE, config_value, 23) FROM dbo.etl_config WHERE config_key = @key);
END
GO

/* Gom mọi biến thể Yes/Y/yes/1 và No/N/no/0 về 1/0; giá trị lạ trả NULL để bị loại có lý do. */
CREATE OR ALTER FUNCTION clean.fn_yes_no_to_bit (@value NVARCHAR(50))
RETURNS BIT
AS
BEGIN
    RETURN CASE UPPER(LTRIM(RTRIM(@value)))
        WHEN 'YES' THEN 1 WHEN 'Y' THEN 1 WHEN '1' THEN 1 WHEN 'TRUE' THEN 1
        WHEN 'NO' THEN 0 WHEN 'N' THEN 0 WHEN '0' THEN 0 WHEN 'FALSE' THEN 0
    END;
END
GO

/* Chuẩn hoá giá trị cột dịch vụ về đúng bộ nhãn của nguồn gốc. */
CREATE OR ALTER FUNCTION clean.fn_normalize_service_value (@value NVARCHAR(50))
RETURNS NVARCHAR(30)
AS
BEGIN
    DECLARE @s NVARCHAR(50) = UPPER(LTRIM(RTRIM(@value)));
    RETURN CASE
        WHEN clean.fn_yes_no_to_bit(@s) = 1 THEN N'Yes'
        WHEN clean.fn_yes_no_to_bit(@s) = 0 THEN N'No'
        WHEN @s = N'NO INTERNET SERVICE' THEN N'No internet service'
        WHEN @s = N'NO PHONE SERVICE' THEN N'No phone service'
        WHEN @s = N'DSL' THEN N'DSL'
        WHEN @s = N'FIBER OPTIC' THEN N'Fiber optic'
    END;
END
GO

/* Nhận diện định dạng chuỗi ngày; dùng cho cả bước parse lẫn báo cáo chất lượng dữ liệu. */
CREATE OR ALTER FUNCTION clean.fn_date_format (@value NVARCHAR(100))
RETURNS VARCHAR(20)
AS
BEGIN
    DECLARE @s NVARCHAR(100) = LTRIM(RTRIM(@value));
    RETURN CASE
        WHEN @s IS NULL OR @s = N'' THEN 'EMPTY'
        WHEN @s LIKE '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]%' THEN 'ISO'
        WHEN @s LIKE '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]%' THEN 'DD/MM/YYYY'
        WHEN @s LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN 'YYYYMMDD'
        WHEN @s LIKE '[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9][0-9][0-9]%' THEN 'DD-MON-YYYY'
        ELSE 'UNKNOWN'
    END;
END
GO

/*
  Parse chuỗi ngày/giờ nhiều định dạng. Dạng dd/mm/yyyy được hiểu là NGÀY trước THÁNG
  (quy ước nhập liệu ở Việt Nam). Tên tháng tiếng Anh được tra bằng bảng cố định thay vì
  dựa vào SET LANGUAGE, để kết quả không phụ thuộc cấu hình ngôn ngữ của phiên kết nối.
*/
CREATE OR ALTER FUNCTION clean.fn_parse_datetime (@value NVARCHAR(100))
RETURNS DATETIME2(0)
AS
BEGIN
    DECLARE @s NVARCHAR(100) = LTRIM(RTRIM(@value));
    DECLARE @fmt VARCHAR(20) = clean.fn_date_format(@s);
    IF @fmt = 'ISO' RETURN TRY_CONVERT(DATETIME2(0), @s, 120);
    IF @fmt = 'DD/MM/YYYY' RETURN TRY_CONVERT(DATETIME2(0), @s, 103);
    IF @fmt = 'YYYYMMDD' RETURN TRY_CONVERT(DATETIME2(0), @s, 112);
    IF @fmt = 'DD-MON-YYYY'
    BEGIN
        DECLARE @pos INT = CHARINDEX(UPPER(SUBSTRING(@s, 4, 3)), 'JANFEBMARAPRMAYJUNJULAUGSEPOCTNOVDEC');
        IF @pos = 0 OR @pos % 3 <> 1 RETURN NULL;
        DECLARE @d DATE = TRY_CONVERT(DATE, CONCAT(SUBSTRING(@s, 8, 4), RIGHT(CONCAT('0', (@pos + 2) / 3), 2), LEFT(@s, 2)), 112);
        DECLARE @time_part NVARCHAR(30) = LTRIM(SUBSTRING(@s, 12, 30));
        DECLARE @t TIME(0) = CASE WHEN @time_part = N'' THEN CAST('00:00' AS TIME(0)) ELSE TRY_CONVERT(TIME(0), @time_part) END;
        IF @d IS NULL OR @t IS NULL RETURN NULL;
        RETURN DATEADD(SECOND, DATEDIFF(SECOND, CAST('00:00' AS TIME(0)), @t), CAST(@d AS DATETIME2(0)));
    END
    RETURN NULL;
END
GO

/*
  Ghi các dòng trong bảng tạm #reject (do proc gọi tạo) vào clean.rejected_records.
  Nếu #reject.raw_record trống, lấy nguyên dòng stg tương ứng dạng JSON để truy vết.
*/
CREATE OR ALTER PROCEDURE clean.usp_write_rejects
    @batch_id UNIQUEIDENTIFIER, @source_table NVARCHAR(128)
AS
BEGIN
    SET NOCOUNT ON;
    IF OBJECT_ID(@source_table) IS NULL
        THROW 50001, N'usp_write_rejects: bảng nguồn không tồn tại', 1;
    DECLARE @qualified NVARCHAR(300) = QUOTENAME(PARSENAME(@source_table, 2)) + N'.' + QUOTENAME(PARSENAME(@source_table, 1));
    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO clean.rejected_records
            (batch_id, source_table, stg_row_id, business_key, reason_code, reason_detail, raw_record, rejected_at)
        SELECT @batch_id, @source_table, r.stg_row_id, r.business_key, r.reason_code, r.reason_detail,
               COALESCE(r.raw_record,
                        (SELECT s.* FROM ' + @qualified + N' s WHERE s.stg_row_id = r.stg_row_id
                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)),
               SYSDATETIME()
        FROM #reject r;';
    EXEC sp_executesql @sql, N'@batch_id UNIQUEIDENTIFIER, @source_table NVARCHAR(128)', @batch_id, @source_table;
END
GO

/* Tóm tắt #reject thành chuỗi "rejected 45: DUPLICATE_KEY=45" để ghi vào etl_log.message. */
CREATE OR ALTER PROCEDURE clean.usp_reject_summary @message NVARCHAR(4000) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @message = CONCAT(N'rejected ', (SELECT COUNT(*) FROM #reject),
        N': ' + (SELECT STRING_AGG(CONCAT(reason_code, N'=', n), N', ')
                 FROM (SELECT reason_code, COUNT(*) AS n FROM #reject GROUP BY reason_code) x));
END
GO
