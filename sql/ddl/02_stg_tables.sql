/*
  Tầng staging: giữ NGUYÊN TRẠNG dữ liệu nguồn.

  Quy ước chung cho mọi bảng stg:
  - stg_row_id   : định danh dòng trong lần nạp, để clean.rejected_records trỏ ngược về đúng dòng lỗi.
  - load_date    : thời điểm bắt đầu batch nạp (cùng giá trị cho cả batch, tiện truy vết).
  - source_system: hệ thống nguồn.
  - Không có khoá chính/ràng buộc nghiệp vụ: stg phải nhận được cả dữ liệu sai (trùng khoá, NULL, âm),
    nếu không lỗi sẽ bị chặn ngay lúc nạp và mất dấu vết.
  - Nguồn là database: giữ kiểu dữ liệu của nguồn. Nguồn là file/API: mọi cột là chuỗi, vì
    ép kiểu là việc của tầng clean.

  stg được nạp lại toàn bộ mỗi lần chạy nên DROP/CREATE ở đây là an toàn.
*/
DROP TABLE IF EXISTS stg.crm_customers;
CREATE TABLE stg.crm_customers (
    stg_row_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    customer_id     NVARCHAR(20)  NULL,
    gender          NVARCHAR(20)  NULL,
    senior_citizen  INT           NULL,
    partner         NVARCHAR(10)  NULL,
    dependents      NVARCHAR(10)  NULL,
    created_at      DATETIME2(0)  NULL,
    updated_at      DATETIME2(0)  NULL,
    load_date       DATETIME2(0)  NOT NULL,
    source_system   NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.crm_contracts;
CREATE TABLE stg.crm_contracts (
    stg_row_id        BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    contract_id       NVARCHAR(20)  NULL,
    customer_id       NVARCHAR(20)  NULL,
    contract_type     NVARCHAR(40)  NULL,
    paperless_billing NVARCHAR(10)  NULL,
    payment_method    NVARCHAR(60)  NULL,
    monthly_charges   DECIMAL(10,2) NULL,
    total_charges     NVARCHAR(20)  NULL,
    tenure_months     INT           NULL,
    start_date        NVARCHAR(30)  NULL,
    end_date          NVARCHAR(30)  NULL,
    contract_status   NVARCHAR(20)  NULL,
    churn_flag        NVARCHAR(10)  NULL,
    load_date         DATETIME2(0)  NOT NULL,
    source_system     NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.crm_services;
CREATE TABLE stg.crm_services (
    stg_row_id         BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    customer_id        NVARCHAR(20) NULL,
    phone_service      NVARCHAR(30) NULL,
    multiple_lines     NVARCHAR(30) NULL,
    internet_service   NVARCHAR(30) NULL,
    online_security    NVARCHAR(30) NULL,
    online_backup      NVARCHAR(30) NULL,
    device_protection  NVARCHAR(30) NULL,
    tech_support       NVARCHAR(30) NULL,
    streaming_tv       NVARCHAR(30) NULL,
    streaming_movies   NVARCHAR(30) NULL,
    load_date          DATETIME2(0) NOT NULL,
    source_system      NVARCHAR(30) NOT NULL
);

DROP TABLE IF EXISTS stg.billing_invoices;
CREATE TABLE stg.billing_invoices (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    invoice_id     NVARCHAR(30)  NULL,
    customer_id    NVARCHAR(30)  NULL,
    billing_month  DATE          NULL,
    invoice_date   DATE          NULL,
    due_date       DATE          NULL,
    amount_usd     DECIMAL(10,2) NULL,
    currency       CHAR(3)       NULL,
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.billing_payments;
CREATE TABLE stg.billing_payments (
    stg_row_id      BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    payment_id      NVARCHAR(20)  NULL,
    invoice_id      NVARCHAR(30)  NULL,
    customer_id     NVARCHAR(30)  NULL,
    payment_date    DATE          NULL,
    amount_usd      DECIMAL(10,2) NULL,
    payment_method  NVARCHAR(60)  NULL,
    load_date       DATETIME2(0)  NOT NULL,
    source_system   NVARCHAR(30)  NOT NULL
);

/*
  File Excel do người nhập tay: vị trí và tên cột không ổn định giữa các sheet/các lần gửi.
  Lưu dạng dài (1 dòng = 1 ô) kèm tên cột gốc, để việc nhận diện cột bằng quy tắc nằm ở tầng clean
  và không phải sửa loader mỗi khi Finance đổi tiêu đề.
*/
DROP TABLE IF EXISTS stg.finance_targets_cells;
CREATE TABLE stg.finance_targets_cells (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    source_file    NVARCHAR(260) NOT NULL,
    sheet_name     NVARCHAR(100) NOT NULL,
    excel_row      INT           NOT NULL,
    column_letter  VARCHAR(3)    NOT NULL,
    header_text    NVARCHAR(200) NULL,   -- tiêu đề cột gốc, giữ nguyên khoảng trắng/dấu
    cell_value     NVARCHAR(400) NULL,   -- giá trị ô dạng chuỗi
    cell_type      VARCHAR(20)   NULL,   -- kiểu Excel lưu (number/datetime/string) để clean biết cách ép
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.ticket_support_tickets;
CREATE TABLE stg.ticket_support_tickets (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    source_file    NVARCHAR(260) NOT NULL,
    source_line    INT           NOT NULL,   -- số dòng trong file CSV (dòng header = 1)
    ticket_id      NVARCHAR(100) NULL,
    customer_id    NVARCHAR(100) NULL,
    created_at     NVARCHAR(100) NULL,
    category       NVARCHAR(100) NULL,
    priority       NVARCHAR(100) NULL,
    channel        NVARCHAR(100) NULL,
    status         NVARCHAR(100) NULL,
    resolved_at    NVARCHAR(100) NULL,
    load_date      DATETIME2(0)  NOT NULL,
    source_system  NVARCHAR(30)  NOT NULL
);

DROP TABLE IF EXISTS stg.api_fx_rates;
CREATE TABLE stg.api_fx_rates (
    stg_row_id     BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    rate_month     NVARCHAR(20)   NULL,
    rate_date      NVARCHAR(20)   NULL,
    usd_vnd        NVARCHAR(50)   NULL,
    provider       NVARCHAR(100)  NULL,
    granularity    NVARCHAR(30)   NULL,
    raw_json       NVARCHAR(1000) NULL,  -- bản ghi gốc từ API, phòng khi cần đối chiếu
    load_date      DATETIME2(0)   NOT NULL,
    source_system  NVARCHAR(30)   NOT NULL
);
