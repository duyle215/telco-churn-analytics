/*
  TelcoDW: schema theo tầng và bảng log ETL.

  stg   : bản sao nguyên trạng của nguồn, nạp lại toàn bộ mỗi lần chạy (không làm sạch).
  clean : dữ liệu đã chuẩn hoá kiểu, loại trùng, đối chiếu khoá; bản ghi lỗi tách ra rejected_records.
  mart  : star schema phục vụ phân tích và Power BI.

  Script idempotent: chạy lại không xoá lịch sử etl_log.
*/
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO
IF SCHEMA_ID('clean') IS NULL EXEC('CREATE SCHEMA clean');
GO
IF SCHEMA_ID('mart') IS NULL EXEC('CREATE SCHEMA mart');
GO

IF OBJECT_ID('dbo.etl_log') IS NULL
CREATE TABLE dbo.etl_log (
    log_id        BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id      UNIQUEIDENTIFIER NOT NULL,   -- gom các bước của cùng một lần chạy pipeline
    layer         VARCHAR(10)      NOT NULL,   -- stg / clean / mart / dq
    step_name     NVARCHAR(100)    NOT NULL,
    object_name   NVARCHAR(128)    NULL,
    source_system NVARCHAR(30)     NULL,
    rows_read     INT              NULL,
    rows_written  INT              NULL,
    status        VARCHAR(10)      NOT NULL CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),
    started_at    DATETIME2(3)     NOT NULL,
    finished_at   DATETIME2(3)     NULL,
    message       NVARCHAR(4000)   NULL
);
GO

/* Tham số nghiệp vụ dùng chung cho các stored procedure; giá trị được đồng bộ từ src/config.py mỗi lần chạy. */
IF OBJECT_ID('dbo.etl_config') IS NULL
CREATE TABLE dbo.etl_config (
    config_key   VARCHAR(50)    NOT NULL PRIMARY KEY,
    config_value NVARCHAR(100)  NOT NULL,
    description  NVARCHAR(400)  NULL
);
GO
