"""Tái dựng dòng thời gian vòng đời khách hàng từ bảng snapshot gốc.

Bảng gốc chỉ là ảnh chụp 1 thời điểm: Churn = Yes nghĩa là khách rời đi trong tháng chụp.
Nếu dùng nguyên trạng thì mọi khách churn rơi vào cùng 1 tháng, không có xu hướng theo thời gian.

Quy ước (dùng xuyên suốt dự án):
- anchor_month  = tháng rời đi (khách churn) hoặc tháng snapshot (khách còn hoạt động).
- signup_month  = anchor_month - tenure.
- Hoá đơn tính từ signup_month + 1 đến anchor_month, nên mỗi khách có đúng `tenure` hoá đơn
  (khớp TotalCharges ~ tenure x MonthlyCharges) và tháng churn chính là tháng có hoá đơn cuối.
- tenure = 0: khách vừa ký trong tháng snapshot, chưa phát sinh hoá đơn (khớp với việc
  TotalCharges bị trống ở đúng 11 khách này trong dữ liệu gốc).
"""
import numpy as np
import pandas as pd

from src import config

RAW_TO_SNAKE = {
    "customerID": "customer_id",
    "gender": "gender",
    "SeniorCitizen": "senior_citizen",
    "Partner": "partner",
    "Dependents": "dependents",
    "tenure": "tenure",
    "PhoneService": "phone_service",
    "MultipleLines": "multiple_lines",
    "InternetService": "internet_service",
    "OnlineSecurity": "online_security",
    "OnlineBackup": "online_backup",
    "DeviceProtection": "device_protection",
    "TechSupport": "tech_support",
    "StreamingTV": "streaming_tv",
    "StreamingMovies": "streaming_movies",
    "Contract": "contract_type",
    "PaperlessBilling": "paperless_billing",
    "PaymentMethod": "payment_method",
    "MonthlyCharges": "monthly_charges",
    "TotalCharges": "total_charges",
    "Churn": "churn",
}


def load_raw() -> pd.DataFrame:
    # TotalCharges đọc dạng chuỗi để giữ nguyên 11 giá trị trống của nguồn gốc vào CRM.
    df = pd.read_csv(config.RAW_CSV, dtype={"TotalCharges": str})
    return df.rename(columns=RAW_TO_SNAKE)


def churn_month_weights() -> tuple[list[pd.Period], np.ndarray, np.ndarray]:
    """Trọng số chọn tháng rời đi cho khách churn: (các tháng, trọng số chung, trọng số Fiber)."""
    months = [config.CHURN_WINDOW_START + i for i in range(config.CHURN_WINDOW_MONTHS)]
    seasonal = np.array([
        1 + config.CHURN_SEASONALITY_AMPLITUDE * np.cos(2 * np.pi * (m.month - 1) / 12)
        for m in months
    ])
    fiber_boost = np.array([config.FIBER_EVENT_CHURN_MULTIPLIER.get(m, 1.0) for m in months])
    return months, seasonal / seasonal.sum(), (seasonal * fiber_boost) / (seasonal * fiber_boost).sum()


def _random_day_in_month(months: pd.Series, rng: np.random.Generator) -> pd.Series:
    starts = months.dt.start_time
    offsets = np.floor(rng.random(len(months)) * months.dt.days_in_month.to_numpy()).astype(int)
    return starts + pd.to_timedelta(offsets, unit="D")


def build_customer_timeline(raw: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    df = raw.copy()
    df["is_churned"] = df["churn"].eq("Yes")
    df["is_fiber"] = df["internet_service"].eq("Fiber optic")

    months, p_general, p_fiber = churn_month_weights()
    month_codes = np.array([m.ordinal for m in months])
    churn_ordinal = pd.Series(pd.NA, index=df.index, dtype="Int64")
    for mask, p in ((df.is_churned & ~df.is_fiber, p_general), (df.is_churned & df.is_fiber, p_fiber)):
        churn_ordinal[mask] = rng.choice(month_codes, size=int(mask.sum()), p=p)

    anchor_ordinal = churn_ordinal.fillna(config.SNAPSHOT_MONTH.ordinal).astype(int)
    df["churn_month"] = pd.PeriodIndex.from_ordinals(churn_ordinal.fillna(0).astype(int), freq="M")
    df.loc[~df.is_churned, "churn_month"] = pd.NaT
    df["last_billed_month"] = pd.PeriodIndex.from_ordinals(anchor_ordinal, freq="M")
    df["signup_month"] = pd.PeriodIndex.from_ordinals(anchor_ordinal - df["tenure"], freq="M")
    df["first_billed_month"] = df["signup_month"] + 1

    df["signup_date"] = _random_day_in_month(df["signup_month"], rng)
    df["end_date"] = pd.NaT
    churned = df.is_churned
    df.loc[churned, "end_date"] = _random_day_in_month(df.loc[churned, "churn_month"], rng)
    df["end_date"] = pd.to_datetime(df["end_date"])

    # MonthlyCharges là giá tại tháng có hoá đơn cuối cùng. Khách Fiber còn dùng dịch vụ sau
    # sự kiện tăng giá thì giá trước sự kiện phải thấp hơn tương ứng.
    df["price_before_event"] = np.where(
        df.is_fiber & (df["last_billed_month"] >= config.FIBER_PRICE_EVENT_MONTH),
        (df["monthly_charges"] / (1 + config.FIBER_PRICE_INCREASE)).round(2),
        df["monthly_charges"],
    )
    return df
