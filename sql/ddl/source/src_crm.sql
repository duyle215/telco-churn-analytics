/*
  Hệ thống nguồn mô phỏng: CRM (database src_crm).

  Thiết kế cố ý "lỏng" giống một CRM đời cũ:
  - customers KHÔNG có khoá chính trên customer_id, nên mới có chuyện trùng khách.
  - Các cột Yes/No và ngày tháng lưu NVARCHAR vì màn hình nhập liệu không ràng buộc định dạng.
  - total_charges giữ kiểu chuỗi như file gốc (có giá trị rỗng).
  Kho dữ liệu (TelcoDW) sẽ phải tự xử lý các vấn đề này, không trông chờ nguồn sạch.
*/
CREATE TABLE dbo.customers (
    customer_id     NVARCHAR(20)  NOT NULL,
    gender          NVARCHAR(20)  NULL,
    senior_citizen  INT           NULL,     -- nguồn gốc dùng 0/1, khác quy ước Yes/No của các cột khác
    partner         NVARCHAR(10)  NULL,
    dependents      NVARCHAR(10)  NULL,
    created_at      DATETIME2(0)  NULL,
    updated_at      DATETIME2(0)  NULL
);
GO

CREATE TABLE dbo.contracts (
    contract_id       NVARCHAR(20)  NOT NULL PRIMARY KEY,
    customer_id       NVARCHAR(20)  NOT NULL,
    contract_type     NVARCHAR(40)  NULL,
    paperless_billing NVARCHAR(10)  NULL,
    payment_method    NVARCHAR(60)  NULL,
    monthly_charges   DECIMAL(10,2) NULL,  -- giá hiện tại của gói (tại tháng có hoá đơn cuối)
    total_charges     NVARCHAR(20)  NULL,  -- số luỹ kế ghi nhận trong CRM, không đối soát với billing
    tenure_months     INT           NULL,
    start_date        NVARCHAR(30)  NULL,
    end_date          NVARCHAR(30)  NULL,
    contract_status   NVARCHAR(20)  NULL,
    churn_flag        NVARCHAR(10)  NULL
);
GO

CREATE TABLE dbo.services (
    customer_id        NVARCHAR(20) NOT NULL,
    phone_service      NVARCHAR(30) NULL,
    multiple_lines     NVARCHAR(30) NULL,
    internet_service   NVARCHAR(30) NULL,
    online_security    NVARCHAR(30) NULL,
    online_backup      NVARCHAR(30) NULL,
    device_protection  NVARCHAR(30) NULL,
    tech_support       NVARCHAR(30) NULL,
    streaming_tv       NVARCHAR(30) NULL,
    streaming_movies   NVARCHAR(30) NULL
);
GO
