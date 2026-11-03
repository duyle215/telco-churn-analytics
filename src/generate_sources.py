"""GIAI ĐOẠN 1: sinh toàn bộ dữ liệu nguồn mô phỏng từ bộ Telco Customer Churn.

Chạy:  python -m src.generate_sources

Đầu ra:
- SQL Server: database src_crm (customers, contracts, services) và src_billing (invoices, payments)
- data/source/targets.xlsx        chỉ tiêu do Finance nhập tay
- data/source/support_tickets.csv export từ hệ thống ticket
- data/source/injected_errors.csv danh sách và số lượng lỗi đã cố ý cài

Mỗi bước sinh có random generator riêng tách từ cùng một seed, để sửa một bước
(ví dụ đổi tham số ticket) không làm xê dịch dữ liệu của các bước khác.
"""
import numpy as np
import pandas as pd

from src import config, db
from src.generate import billing, crm, errors, targets, tickets, timeline

SOURCE_DDL_DIR = config.SQL_DIR / "ddl" / "source"


def main() -> None:
    config.SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    (rng_timeline, rng_invoice, rng_payment, rng_ticket, rng_crm, rng_error) = [
        np.random.default_rng(s) for s in np.random.SeedSequence(config.RANDOM_SEED).spawn(6)
    ]
    log = errors.ErrorLog()

    raw = timeline.load_raw()
    tl = timeline.build_customer_timeline(raw, rng_timeline)

    invoices = billing.build_invoices(tl, rng_invoice)
    payments = billing.build_payments(invoices, rng_payment)
    ticket_df = tickets.build_tickets(tl, rng_ticket)
    actuals = targets.monthly_actuals(tl, invoices)
    target_df = targets.build_targets(actuals)

    customers = crm.build_customers(tl, rng_crm)
    contracts = crm.build_contracts(tl)
    services = crm.build_services(tl)

    log.add("crm", "src_crm.dbo.contracts", "total_charges", "blank_value_inherited",
            int(contracts["total_charges"].str.strip().eq("").sum()),
            "Có sẵn trong dữ liệu gốc: TotalCharges rỗng ở khách tenure = 0")
    log.add("crm", "src_crm.dbo.customers", "senior_citizen", "inconsistent_boolean_inherited", len(customers),
            "Có sẵn trong dữ liệu gốc: senior_citizen dùng 0/1 trong khi các cột cờ khác dùng Yes/No")

    customers = errors.duplicate_customers(customers, rng_error, log)
    for col, rate in (("partner", 0.06), ("dependents", 0.06)):
        customers = errors.yes_no_variants(customers, col, rate, rng_error, log, "crm", "src_crm.dbo.customers")
    customers = errors.extra_whitespace(customers, "gender", 80, rng_error, log, "crm", "src_crm.dbo.customers")

    contracts = errors.yes_no_variants(contracts, "paperless_billing", 0.05, rng_error, log, "crm", "src_crm.dbo.contracts")
    contracts = errors.yes_no_variants(contracts, "churn_flag", 0.04, rng_error, log, "crm", "src_crm.dbo.contracts")
    contracts = errors.extra_whitespace(contracts, "contract_type", 120, rng_error, log, "crm", "src_crm.dbo.contracts")
    contracts = errors.extra_whitespace(contracts, "payment_method", 150, rng_error, log, "crm", "src_crm.dbo.contracts")
    for col in ("start_date", "end_date"):
        contracts[col] = errors.mixed_date_format(contracts[col], errors.DATE_FORMATS, rng_error, log,
                                                  "crm", "src_crm.dbo.contracts")

    services = errors.yes_no_variants(services, "phone_service", 0.03, rng_error, log, "crm", "src_crm.dbo.services")
    services = errors.extra_whitespace(services, "customer_id", 60, rng_error, log, "crm", "src_crm.dbo.services")

    invoices, payments = errors.drop_outage_month(invoices, payments, log)
    invoices, payments = errors.orphan_invoices(invoices, payments, set(tl["customer_id"]), rng_error, log)
    invoices = errors.invoice_amount_errors(invoices, rng_error, log)
    invoices = errors.extra_whitespace(invoices, "customer_id", 400, rng_error, log, "billing", "src_billing.dbo.invoices")

    ticket_df = errors.extra_whitespace(ticket_df, "customer_id", 90, rng_error, log, "ticket_csv", "support_tickets.csv")
    for col in ("created_at", "resolved_at"):
        ticket_df[col] = errors.mixed_date_format(ticket_df[col], errors.DATETIME_FORMATS, rng_error, log,
                                                  "ticket_csv", "support_tickets.csv")

    log.extend(targets.write_targets_excel(target_df))
    ticket_df.to_csv(config.TICKETS_CSV, index=False, encoding="utf-8")

    write_crm(customers, contracts, services)
    write_billing(invoices, payments)

    error_log = log.to_frame()
    error_log.to_csv(config.INJECTED_ERRORS_CSV, index=False, encoding="utf-8-sig")
    print_summary(tl, actuals, customers, contracts, services, invoices, payments, ticket_df, error_log)


def write_crm(customers: pd.DataFrame, contracts: pd.DataFrame, services: pd.DataFrame) -> None:
    db.recreate_database(config.SRC_CRM_DB)
    with db.connect(config.SRC_CRM_DB) as conn:
        db.run_sql_file(conn, SOURCE_DDL_DIR / "src_crm.sql")
        db.bulk_insert(conn, "dbo.customers", customers)
        db.bulk_insert(conn, "dbo.contracts", contracts)
        db.bulk_insert(conn, "dbo.services", services)


def write_billing(invoices: pd.DataFrame, payments: pd.DataFrame) -> None:
    inv_cols = ["invoice_id", "customer_id", "billing_month", "invoice_date", "due_date", "amount_usd"]
    inv = invoices[inv_cols].copy()
    inv["billing_month"] = inv["billing_month"].dt.start_time
    for col in ("billing_month", "invoice_date", "due_date"):
        inv[col] = inv[col].dt.date
    pay = payments.copy()
    pay["payment_date"] = pay["payment_date"].dt.date

    db.recreate_database(config.SRC_BILLING_DB)
    with db.connect(config.SRC_BILLING_DB) as conn:
        db.run_sql_file(conn, SOURCE_DDL_DIR / "src_billing.sql")
        db.bulk_insert(conn, "dbo.invoices", inv.sort_values("invoice_id"))
        db.bulk_insert(conn, "dbo.payments", pay.sort_values("payment_id"))


def print_summary(tl, actuals, customers, contracts, services, invoices, payments, ticket_df, error_log) -> None:
    print("== Số dòng đã ghi")
    for name, df in [("src_crm.customers", customers), ("src_crm.contracts", contracts),
                     ("src_crm.services", services), ("src_billing.invoices", invoices),
                     ("src_billing.payments", payments), ("support_tickets.csv", ticket_df)]:
        print(f"  {name:<24}{len(df):>9,}")

    print("== Khách churn theo tháng (tổng / Fiber), trước khi cài lỗi")
    by_month = tl.dropna(subset=["churn_month"]).groupby("churn_month").agg(
        total=("customer_id", "size"), fiber=("is_fiber", "sum"))
    print(by_month.T.to_string())

    window = actuals.loc[config.CHURN_WINDOW_START:config.SNAPSHOT_MONTH]
    print("== KPI thực tế trong cửa sổ 24 tháng (dữ liệu chuẩn, chưa cài lỗi)")
    print(window[["active_customers", "churners", "churn_rate", "mrr_usd"]].round(4).to_string())

    print("== Lỗi đã cài")
    print(error_log[["error_id", "object", "column", "error_type", "rows_affected"]].to_string(index=False))


if __name__ == "__main__":
    main()
