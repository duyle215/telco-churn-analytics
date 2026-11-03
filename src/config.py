"""Cấu hình dùng chung cho toàn pipeline.

Mọi tham số mô phỏng (seed, ngày snapshot, sự kiện tăng giá...) tập trung ở đây để
khi phỏng vấn có thể chỉ ra ngay "giả định nằm ở đâu" và chạy lại cho ra kết quả y hệt.
"""
import os
from pathlib import Path

import pandas as pd

ROOT_DIR = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT_DIR / "data"
RAW_CSV = DATA_DIR / "WA_Fn-UseC_-Telco-Customer-Churn.csv"
SOURCE_DIR = DATA_DIR / "source"          # nơi đặt các file "export" từ phòng ban / hệ thống
SQL_DIR = ROOT_DIR / "sql"

TARGETS_XLSX = SOURCE_DIR / "targets.xlsx"
TICKETS_CSV = SOURCE_DIR / "support_tickets.csv"
INJECTED_ERRORS_CSV = SOURCE_DIR / "injected_errors.csv"

RANDOM_SEED = 42

SNAPSHOT_DATE = pd.Timestamp("2025-12-31")
SNAPSHOT_MONTH = SNAPSHOT_DATE.to_period("M")
# Dữ liệu gốc chỉ cho biết "đã churn" chứ không cho biết khi nào; ta rải tháng rời đi
# trong 24 tháng gần nhất để có chuỗi thời gian phân tích được.
CHURN_WINDOW_START = pd.Period("2024-01", "M")
CHURN_WINDOW_MONTHS = 24

# Biên độ mùa vụ của churn: đỉnh tháng 1 (khách xem lại hợp đồng sau Tết/năm mới),
# đáy giữa năm. Giữ nhỏ để không lấn át sự kiện bất thường cần phát hiện.
CHURN_SEASONALITY_AMPLITUDE = 0.12

FIBER_PRICE_EVENT_MONTH = pd.Period("2025-03", "M")
FIBER_PRICE_INCREASE = 0.15
# Hệ số nhân xác suất rơi vào tháng đó của khách Fiber churn. Đỉnh ở tháng thứ 2 vì
# khách thường phản ứng sau khi nhận hoá đơn mới đầu tiên, không phải ngay lập tức.
FIBER_EVENT_CHURN_MULTIPLIER = {
    pd.Period("2025-03", "M"): 1.6,
    pd.Period("2025-04", "M"): 2.6,
    pd.Period("2025-05", "M"): 1.9,
}

# Hệ thống ticket mới chỉ có dữ liệu từ sau đợt chuyển đổi, nên export không có lịch sử cũ hơn.
TICKET_SYSTEM_START = pd.Timestamp("2023-01-01")

# Tháng hệ thống billing gặp sự cố, không sinh hoá đơn.
BILLING_OUTAGE_MONTH = pd.Period("2024-08", "M")

SQL_SERVER = os.getenv("TELCO_SQL_SERVER", "localhost")
SQL_DRIVER = os.getenv("TELCO_SQL_DRIVER", "ODBC Driver 17 for SQL Server")
SRC_CRM_DB = "src_crm"
SRC_BILLING_DB = "src_billing"
DW_DB = "TelcoDW"

