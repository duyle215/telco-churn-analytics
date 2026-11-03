"""Tách bảng phẳng gốc thành 3 bảng CRM chuẩn hoá: customers, contracts, services.

- customers: thông tin nhân khẩu học (đổi rất ít).
- contracts: điều khoản hợp đồng và trạng thái vòng đời (ngày bắt đầu/kết thúc, churn).
- services: hồ sơ dịch vụ đang dùng. Giả định không đổi trong suốt vòng đời khách.
"""
import numpy as np
import pandas as pd


def build_customers(timeline: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    created_at = timeline["signup_date"] + pd.to_timedelta(rng.integers(8 * 3600, 20 * 3600, len(timeline)), unit="s")
    return pd.DataFrame({
        "customer_id": timeline["customer_id"],
        "gender": timeline["gender"],
        "senior_citizen": timeline["senior_citizen"],
        "partner": timeline["partner"],
        "dependents": timeline["dependents"],
        "created_at": created_at,
        "updated_at": created_at,
    })


def build_contracts(timeline: pd.DataFrame) -> pd.DataFrame:
    churned = timeline["is_churned"]
    return pd.DataFrame({
        "contract_id": "CT" + (timeline.index + 1).astype(str).str.zfill(6),
        "customer_id": timeline["customer_id"],
        "contract_type": timeline["contract_type"],
        "paperless_billing": timeline["paperless_billing"],
        "payment_method": timeline["payment_method"],
        "monthly_charges": timeline["monthly_charges"],
        "total_charges": timeline["total_charges"],
        "tenure_months": timeline["tenure"],
        "start_date": timeline["signup_date"],
        "end_date": timeline["end_date"],
        "contract_status": np.where(churned, "Terminated", "Active"),
        "churn_flag": timeline["churn"],
    })


SERVICE_COLUMNS = ["phone_service", "multiple_lines", "internet_service", "online_security",
                   "online_backup", "device_protection", "tech_support", "streaming_tv", "streaming_movies"]


def build_services(timeline: pd.DataFrame) -> pd.DataFrame:
    return timeline[["customer_id", *SERVICE_COLUMNS]].copy()
