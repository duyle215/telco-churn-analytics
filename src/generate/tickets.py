"""Sinh ticket hỗ trợ khách hàng, mô phỏng file export từ hệ thống ticket.

Số ticket được sinh theo Poisson cho từng khách x tháng, với cường độ tăng khi khách
không có TechSupport, dùng Fiber, sắp rời đi, và khi có sự kiện tăng giá Fiber
(khiếu nại hoá đơn). Đây là các tương quan mà phần phân tích phải tìm lại được.
"""
import numpy as np
import pandas as pd

from src import config

BASE_TICKETS_PER_MONTH = 0.03
NO_INTERNET_MULTIPLIER = 0.4
FIBER_MULTIPLIER = 1.4
NO_TECH_SUPPORT_MULTIPLIER = 2.2
CHURNER_MULTIPLIER = 1.5
PRE_CHURN_MULTIPLIER = 3.0
PRE_CHURN_WINDOW_MONTHS = 3
# Cường độ khiếu nại hoá đơn thêm vào cho khách Fiber sau khi tăng giá.
FIBER_EVENT_BILLING_TICKETS = {
    pd.Period("2025-03", "M"): 0.10,
    pd.Period("2025-04", "M"): 0.08,
    pd.Period("2025-05", "M"): 0.04,
}

CATEGORIES = ["Technical", "Billing", "Account", "Service Request"]
CATEGORY_P_INTERNET = [0.50, 0.22, 0.13, 0.15]
CATEGORY_P_NO_INTERNET = [0.20, 0.40, 0.25, 0.15]
CHANNELS = ["Phone", "Chat", "Email", "Store"]
CHANNEL_P = [0.45, 0.25, 0.20, 0.10]
PRIORITIES = ["High", "Medium", "Low"]


def _customer_months(timeline: pd.DataFrame) -> pd.DataFrame:
    start_floor = config.TICKET_SYSTEM_START.to_period("M")
    tl = timeline[timeline["last_billed_month"] >= start_floor].copy()
    first = tl["signup_month"].where(tl["signup_month"] > start_floor, start_floor)
    tl["n_months"] = tl["last_billed_month"].array.asi8 - first.array.asi8 + 1
    tl["first_month"] = first
    cm = tl.loc[tl.index.repeat(tl["n_months"])].reset_index(drop=True)
    cm["month"] = cm["first_month"] + cm.groupby("customer_id").cumcount()
    cm["months_to_last"] = cm["last_billed_month"].array.asi8 - cm["month"].array.asi8
    return cm


def build_tickets(timeline: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    cm = _customer_months(timeline)
    has_internet = cm["internet_service"].ne("No")

    lam = np.full(len(cm), BASE_TICKETS_PER_MONTH)
    lam = np.where(~has_internet, lam * NO_INTERNET_MULTIPLIER, lam)
    lam = np.where(cm["is_fiber"], lam * FIBER_MULTIPLIER, lam)
    lam = np.where(cm["tech_support"].eq("No"), lam * NO_TECH_SUPPORT_MULTIPLIER, lam)
    lam = np.where(cm["is_churned"], lam * CHURNER_MULTIPLIER, lam)
    pre_churn = cm["is_churned"] & (cm["months_to_last"] < PRE_CHURN_WINDOW_MONTHS)
    lam = np.where(pre_churn, lam * PRE_CHURN_MULTIPLIER, lam)
    event_lam = np.where(cm["is_fiber"], cm["month"].map(FIBER_EVENT_BILLING_TICKETS).fillna(0.0), 0.0)

    regular_n = rng.poisson(lam)
    event_n = rng.poisson(event_lam)

    regular = cm.loc[cm.index.repeat(regular_n)].reset_index(drop=True)
    reg_internet = regular["internet_service"].ne("No").to_numpy()
    u = rng.random(len(regular))
    cat_internet = np.searchsorted(np.cumsum(CATEGORY_P_INTERNET), u, side="right")
    cat_no_internet = np.searchsorted(np.cumsum(CATEGORY_P_NO_INTERNET), u, side="right")
    regular["category"] = np.array(CATEGORIES)[np.where(reg_internet, cat_internet, cat_no_internet)]

    event = cm.loc[cm.index.repeat(event_n)].reset_index(drop=True)
    event["category"] = "Billing"

    t = pd.concat([regular, event], ignore_index=True)
    t["channel"] = rng.choice(CHANNELS, size=len(t), p=CHANNEL_P)
    is_tech = t["category"].eq("Technical").to_numpy()
    t["priority"] = np.where(
        is_tech,
        rng.choice(PRIORITIES, size=len(t), p=[0.30, 0.50, 0.20]),
        rng.choice(PRIORITIES, size=len(t), p=[0.10, 0.50, 0.40]),
    )

    month_start = t["month"].dt.start_time
    seconds_in_month = t["month"].dt.days_in_month.to_numpy() * 86400
    created = month_start + pd.to_timedelta((rng.random(len(t)) * seconds_in_month).astype(int), unit="s")
    # Ticket không thể trước ngày ký hay sau ngày rời đi / ngày snapshot.
    upper = t["end_date"].fillna(config.SNAPSHOT_DATE) + pd.Timedelta(hours=23, minutes=59)
    created = created.clip(lower=t["signup_date"], upper=upper)
    t["created_at"] = created.dt.floor("s")

    mean_hours = np.where(is_tech, 36.0, 18.0)
    resolve_hours = 1 + rng.exponential(mean_hours)
    resolved = t["created_at"] + pd.to_timedelta(resolve_hours * 3600, unit="s").floor("s")
    still_open = resolved > config.SNAPSHOT_DATE + pd.Timedelta(hours=23, minutes=59, seconds=59)
    t["resolved_at"] = resolved.where(~still_open)
    t["status"] = np.where(still_open, "Open", "Closed")

    t = t.sort_values(["created_at", "customer_id"]).reset_index(drop=True)
    t["ticket_id"] = "TCK-" + (t.index + 1).astype(str).str.zfill(6)
    return t[["ticket_id", "customer_id", "created_at", "category", "priority", "channel",
              "status", "resolved_at"]]
