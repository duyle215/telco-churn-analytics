/*
  TelcoDW: one schema per layer, plus the ETL log table.

  stg   : as-is copy of the sources, fully reloaded on every run (no cleaning).
  clean : typed, de-duplicated, key-checked data; unusable rows go to rejected_records.
  mart  : star schema for analysis and Power BI.

  Idempotent script: re-running it keeps the etl_log history.
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
    batch_id      UNIQUEIDENTIFIER NOT NULL,   -- groups the steps of one pipeline run
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

/* Business parameters shared by the stored procedures; synced from src/config.py on every run. */
IF OBJECT_ID('dbo.etl_config') IS NULL
CREATE TABLE dbo.etl_config (
    config_key   VARCHAR(50)    NOT NULL PRIMARY KEY,
    config_value NVARCHAR(100)  NOT NULL,
    description  NVARCHAR(400)  NULL
);
GO
