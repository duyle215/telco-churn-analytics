"""Configuration shared by the whole pipeline.

Every simulation parameter (seed, snapshot date, price event...) lives here, so it is easy to point at
"where the assumptions are", and a re-run gives exactly the same result.
"""
import os
from pathlib import Path

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / "data"
RAW_CSV = DATA_DIR / "WA_Fn-UseC_-Telco-Customer-Churn.csv"
SOURCE_DIR = DATA_DIR / "source"          # where the "exports" from departments / systems are placed
SQL_DIR = ROOT_DIR / "sql"

TARGETS_XLSX = SOURCE_DIR / "targets.xlsx"
TICKETS_CSV = SOURCE_DIR / "support_tickets.csv"
INJECTED_ERRORS_CSV = SOURCE_DIR / "injected_errors.csv"

RANDOM_SEED = 42

SNAPSHOT_DATE = pd.Timestamp("2025-12-31")
SNAPSHOT_MONTH = SNAPSHOT_DATE.to_period("M")
# The source data only says a customer churned, not when; churn months are spread
# over the last 24 months to get an analysable time series.
CHURN_WINDOW_START = pd.Period("2024-01", "M")
CHURN_WINDOW_MONTHS = 24

# Churn seasonality amplitude: peak in January (customers review contracts after the new year / Tet),
# trough mid-year. Kept small so it does not hide the anomaly to be detected.
CHURN_SEASONALITY_AMPLITUDE = 0.12

FIBER_PRICE_EVENT_MONTH = pd.Period("2025-03", "M")
FIBER_PRICE_INCREASE = 0.15
# Multiplier on the probability that a Fiber churner leaves in that month. It only moves WHEN Fiber churners
# leave, not how many. The peak is in the second month because customers react to the first new bill.
FIBER_EVENT_CHURN_MULTIPLIER = {
    pd.Period("2025-03", "M"): 1.6,
    pd.Period("2025-04", "M"): 2.6,
    pd.Period("2025-05", "M"): 1.9,
}

# The new ticket system only has data since the migration, so the export has no older history.
TICKET_SYSTEM_START = pd.Timestamp("2023-01-01")

# Month in which the billing system failed and produced no invoices.
BILLING_OUTAGE_MONTH = pd.Period("2024-08", "M")

SQL_SERVER = os.getenv("TELCO_SQL_SERVER", "localhost")
SQL_DRIVER = os.getenv("TELCO_SQL_DRIVER", "ODBC Driver 17 for SQL Server")
SRC_CRM_DB = "src_crm"
SRC_BILLING_DB = "src_billing"
DW_DB = "TelcoDW"

