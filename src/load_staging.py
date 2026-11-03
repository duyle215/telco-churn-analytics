"""STAGE 2: load the 4 source types into TelcoDW.stg AS IS.

Run:  python -m src.load_staging

Principles:
- No cleaning, no type conversion, no row filtering. Only load_date and source_system are added.
- Full reload: stg is recreated on every run, so repeated runs give the same result.
- Each table loads in its own transaction and writes 1 row to dbo.etl_log.
  Rows read from the source must equal rows written to stg, otherwise the step is FAILED.
- CRM/Billing are read through a separate connection to the source database and written to the DW, not with
  a cross-database INSERT ... SELECT: in practice source systems live on a different server from the warehouse.
"""
import csv
import datetime as dt
import json

import pandas as pd
from openpyxl import load_workbook
from openpyxl.utils import get_column_letter

from src import config, db
from src.etl_log import EtlLogger, StepResult
from src.fx import client as fx_client

DW_DDL_DIR = config.SQL_DIR / "ddl"
FETCH_CHUNK = 20000

DB_SOURCES = [
    # (source_system, source database, source table, stg table, column list)
    ("CRM", config.SRC_CRM_DB, "dbo.customers", "stg.crm_customers",
     ["customer_id", "gender", "senior_citizen", "partner", "dependents", "created_at", "updated_at"]),
    ("CRM", config.SRC_CRM_DB, "dbo.contracts", "stg.crm_contracts",
     ["contract_id", "customer_id", "contract_type", "paperless_billing", "payment_method", "monthly_charges",
      "total_charges", "tenure_months", "start_date", "end_date", "contract_status", "churn_flag"]),
    ("CRM", config.SRC_CRM_DB, "dbo.services", "stg.crm_services",
     ["customer_id", "phone_service", "multiple_lines", "internet_service", "online_security", "online_backup",
      "device_protection", "tech_support", "streaming_tv", "streaming_movies"]),
    ("BILLING", config.SRC_BILLING_DB, "dbo.invoices", "stg.billing_invoices",
     ["invoice_id", "customer_id", "billing_month", "invoice_date", "due_date", "amount_usd", "currency"]),
    ("BILLING", config.SRC_BILLING_DB, "dbo.payments", "stg.billing_payments",
     ["payment_id", "invoice_id", "customer_id", "payment_date", "amount_usd", "payment_method"]),
]

TICKET_COLUMNS = ["ticket_id", "customer_id", "created_at", "category", "priority", "channel",
                  "status", "resolved_at"]
# Header row of a target sheet: the first row with at least this many non-empty cells
# (the title/author rows above it have only 1 cell).
EXCEL_HEADER_MIN_CELLS = 3


def main() -> None:
    db.create_database_if_missing(config.DW_DB)
    with db.connect(config.DW_DB) as conn:
        db.run_sql_file(conn, DW_DDL_DIR / "01_schemas_and_etl_log.sql")
        db.run_sql_file(conn, DW_DDL_DIR / "02_stg_tables.sql")

    load_date = dt.datetime.now().replace(microsecond=0)
    log = EtlLogger(layer="stg")
    try:
        with db.connect(config.DW_DB) as dw:
            for source_system, src_db, src_table, stg_table, columns in DB_SOURCES:
                run_step(log, dw, f"load {stg_table}", stg_table, source_system,
                         lambda r, a=(src_db, src_table, stg_table, columns, source_system):
                         copy_db_table(dw, *a, load_date, r))
            run_step(log, dw, "load stg.finance_targets_cells", "stg.finance_targets_cells", "FINANCE_EXCEL",
                     lambda r: load_targets_excel(dw, load_date, r))
            run_step(log, dw, "load stg.ticket_support_tickets", "stg.ticket_support_tickets", "TICKET_CSV",
                     lambda r: load_tickets_csv(dw, load_date, r))
            run_step(log, dw, "load stg.api_fx_rates", "stg.api_fx_rates", "FX_API",
                     lambda r: load_fx_api(dw, load_date, r))
    finally:
        log.close()
    print_summary(log.batch_id)


def run_step(log: EtlLogger, conn, step_name: str, object_name: str, source_system: str, loader) -> None:
    with log.step(step_name, object_name, source_system) as result:
        try:
            loader(result)
            if result.rows_read != result.rows_written:
                raise ValueError(f"Rows read ({result.rows_read}) differ from rows written ({result.rows_written})")
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    print(f"  {object_name:<30} {result.rows_written:>9,} rows  {result.message or ''}")


def copy_db_table(dw, src_db: str, src_table: str, stg_table: str, columns: list[str],
                  source_system: str, load_date: dt.datetime, result: StepResult) -> None:
    col_sql = ", ".join(f"[{c}]" for c in columns)
    with db.connect(src_db) as src:
        cur = src.cursor()
        cur.execute(f"SELECT {col_sql} FROM {src_table}")
        while chunk := cur.fetchmany(FETCH_CHUNK):
            rows = [(*row, load_date, source_system) for row in chunk]
            result.rows_read += len(rows)
            result.rows_written += db.insert_rows(dw, stg_table, [*columns, "load_date", "source_system"], rows)
    result.message = f"from {src_db}.{src_table}"


def _excel_cell_to_raw(value) -> tuple[str | None, str | None]:
    if value is None:
        return None, None
    if isinstance(value, dt.datetime):
        return value.isoformat(sep=" "), "datetime"
    if isinstance(value, (int, float)):
        return str(value), "number"
    return str(value), "string"


def load_targets_excel(dw, load_date: dt.datetime, result: StepResult) -> None:
    wb = load_workbook(config.TARGETS_XLSX, data_only=True, read_only=True)
    rows, skipped = [], []
    for ws in wb.worksheets:
        sheet_rows = list(ws.iter_rows(values_only=True))
        header_idx = next((i for i, r in enumerate(sheet_rows)
                           if sum(v is not None for v in r) >= EXCEL_HEADER_MIN_CELLS), None)
        if header_idx is None:
            raise ValueError(f"Sheet '{ws.title}': header row not found")
        skipped.append(f"{ws.title}: skipped {header_idx} title rows, header on row {header_idx + 1}")
        headers = sheet_rows[header_idx]
        for offset, values in enumerate(sheet_rows[header_idx + 1:], start=header_idx + 2):
            if all(v is None for v in values):
                continue
            result.rows_read += 1
            for col_idx, (header, value) in enumerate(zip(headers, values), start=1):
                if header is None:
                    continue
                raw, cell_type = _excel_cell_to_raw(value)
                rows.append((config.TARGETS_XLSX.name, ws.title, offset, get_column_letter(col_idx),
                             str(header), raw, cell_type, load_date, "FINANCE_EXCEL"))
    wb.close()
    db.insert_rows(dw, "stg.finance_targets_cells",
                   ["source_file", "sheet_name", "excel_row", "column_letter", "header_text", "cell_value",
                    "cell_type", "load_date", "source_system"], rows)
    # The unit counted is an Excel data row; the number of cells written goes into the message.
    result.rows_written = len({(r[1], r[2]) for r in rows})
    result.message = f"{len(rows)} cells; " + "; ".join(skipped)


def load_tickets_csv(dw, load_date: dt.datetime, result: StepResult) -> None:
    with open(config.TICKETS_CSV, encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header != TICKET_COLUMNS:
            raise ValueError(f"CSV structure changed: {header}")
        # Keep empty strings as in the file; deciding that empty = NULL is the clean layer's job.
        rows = [(config.TICKETS_CSV.name, line_no, *values, load_date, "TICKET_CSV")
                for line_no, values in enumerate(reader, start=2)]
    result.rows_read = len(rows)
    result.rows_written = db.insert_rows(dw, "stg.ticket_support_tickets",
                                         ["source_file", "source_line", *TICKET_COLUMNS, "load_date",
                                          "source_system"], rows)


def load_fx_api(dw, load_date: dt.datetime, result: StepResult) -> None:
    first_month = dw.cursor().execute("SELECT MIN(billing_month) FROM stg.billing_invoices").fetchone()[0]
    start = pd.Period(first_month, "M")
    records = fx_client.fetch_monthly_usd_vnd(start, config.SNAPSHOT_MONTH)
    rows = [(r["month"], r["rate_date"], repr(r["usd_vnd"]), r["provider"], r["granularity"],
             json.dumps(r, ensure_ascii=False), load_date, "FX_API") for r in records]
    result.rows_read = len(records)
    result.rows_written = db.insert_rows(dw, "stg.api_fx_rates",
                                         ["rate_month", "rate_date", "usd_vnd", "provider", "granularity",
                                          "raw_json", "load_date", "source_system"], rows)
    providers = sorted({r["provider"] for r in records})
    result.message = f"{start}..{config.SNAPSHOT_MONTH}; provider: {', '.join(providers)}"


def print_summary(batch_id: str) -> None:
    with db.connect(config.DW_DB) as conn:
        rows = conn.cursor().execute(
            "SELECT step_name, status, rows_read, rows_written, "
            "DATEDIFF(millisecond, started_at, finished_at) FROM dbo.etl_log WHERE batch_id = ? ORDER BY log_id",
            batch_id).fetchall()
    print(f"== etl_log batch {batch_id}")
    for step, status, r_read, r_written, ms in rows:
        print(f"  {step:<38} {status:<8} read={r_read:>8,} written={r_written:>8,} {ms:>7,} ms")


if __name__ == "__main__":
    main()
