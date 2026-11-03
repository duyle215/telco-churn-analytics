/*
  Hệ thống nguồn mô phỏng: Billing/ERP (database src_billing).

  Billing là hệ thống riêng, chỉ lưu customer_id dạng chuỗi và KHÔNG có khoá ngoại sang CRM
  (khác database, khác nhà cung cấp phần mềm). Vì vậy có thể tồn tại hoá đơn của khách
  không có trong CRM, và việc đối chiếu khoá là trách nhiệm của tầng DW.
  amount_usd cho phép NULL vì lỗi tích hợp đôi khi đẩy hoá đơn sang mà thiếu số tiền.
*/
CREATE TABLE dbo.invoices (
    invoice_id     NVARCHAR(30)  NOT NULL PRIMARY KEY,
    customer_id    NVARCHAR(30)  NOT NULL,
    billing_month  DATE          NOT NULL,  -- ngày đầu tháng của kỳ cước
    invoice_date   DATE          NOT NULL,  -- xuất hoá đơn cuối kỳ (tính cước sau)
    due_date       DATE          NOT NULL,
    amount_usd     DECIMAL(10,2) NULL,
    currency       CHAR(3)       NOT NULL DEFAULT 'USD'
);
GO

CREATE TABLE dbo.payments (
    payment_id      NVARCHAR(20)  NOT NULL PRIMARY KEY,
    invoice_id      NVARCHAR(30)  NOT NULL,
    customer_id     NVARCHAR(30)  NOT NULL,
    payment_date    DATE          NOT NULL,
    amount_usd      DECIMAL(10,2) NOT NULL,
    payment_method  NVARCHAR(60)  NULL
);
GO
