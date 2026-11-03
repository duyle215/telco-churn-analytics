"""Lấy tỷ giá USD -> VND theo tháng từ API công khai miễn phí (không cần API key).

Nguồn:
1. fawazahmed0/exchange-api (qua CDN jsdelivr, mirror pages.dev): tỷ giá theo ngày,
   chỉ có lịch sử từ 2024-03-02. Lấy tỷ giá của ngày đầu tiên có dữ liệu trong tháng.
2. World Bank, chỉ số PA.NUS.FCRF (tỷ giá chính thức, bình quân năm): dùng cho các tháng
   trước 2024-03 vì nguồn 1 không có. Mọi tháng trong năm nhận cùng một giá trị bình quân năm.

Không có phương án dự phòng bằng dữ liệu giả: API lỗi thì ném lỗi để bước nạp ghi FAILED
vào etl_log, thay vì lặng lẽ nạp một con số không truy được nguồn gốc.
Mỗi bản ghi giữ provider và granularity để tầng DW và báo cáo biết con số đến từ đâu.

Chạy thử:  python -m src.fx.client --start 2018-01 --end 2025-12
"""
import argparse
from concurrent.futures import ThreadPoolExecutor

import pandas as pd
import requests

from src import config

DAILY_API_URLS = [
    "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@{date}/v1/currencies/usd.min.json",
    "https://{date}.currency-api.pages.dev/v1/currencies/usd.min.json",
]
DAILY_API_FIRST_DATE = pd.Timestamp("2024-03-02")
WORLD_BANK_URL = ("https://api.worldbank.org/v2/country/VNM/indicator/PA.NUS.FCRF"
                  "?format=json&date={start}:{end}&per_page=100")
TIMEOUT_SECONDS = 20
MAX_PARALLEL_REQUESTS = 6


def _fetch_daily(month: pd.Period) -> dict:
    rate_date = max(month.start_time, DAILY_API_FIRST_DATE).strftime("%Y-%m-%d")
    last_error = None
    # URL thứ hai là mirror chính thức của cùng bộ dữ liệu, không phải nguồn khác.
    for template in DAILY_API_URLS:
        try:
            resp = requests.get(template.format(date=rate_date), timeout=TIMEOUT_SECONDS)
            resp.raise_for_status()
            payload = resp.json()
            return {"month": str(month), "rate_date": payload["date"], "usd_vnd": payload["usd"]["vnd"],
                    "provider": "fawazahmed0-currency-api", "granularity": "daily"}
        except (requests.RequestException, KeyError, ValueError) as exc:
            last_error = exc
    raise ConnectionError(f"Không lấy được tỷ giá ngày {rate_date}: {last_error}")


def _fetch_world_bank(months: list[pd.Period]) -> list[dict]:
    years = sorted({m.year for m in months})
    resp = requests.get(WORLD_BANK_URL.format(start=years[0], end=years[-1]), timeout=TIMEOUT_SECONDS)
    resp.raise_for_status()
    # Phản hồi World Bank có dạng [metadata, [records]].
    annual = {int(r["date"]): r["value"] for r in resp.json()[1] if r["value"] is not None}
    missing = sorted(set(years) - set(annual))
    if missing:
        raise ConnectionError(f"World Bank chưa có số liệu năm {missing}")
    return [{"month": str(m), "rate_date": f"{m.year}-12-31", "usd_vnd": annual[m.year],
             "provider": "world-bank-PA.NUS.FCRF", "granularity": "annual_average"} for m in months]


def fetch_monthly_usd_vnd(start: pd.Period, end: pd.Period) -> list[dict]:
    months = list(pd.period_range(start, end, freq="M"))
    daily_months = [m for m in months if m.end_time >= DAILY_API_FIRST_DATE]
    annual_months = [m for m in months if m.end_time < DAILY_API_FIRST_DATE]
    records = _fetch_world_bank(annual_months) if annual_months else []
    with ThreadPoolExecutor(max_workers=MAX_PARALLEL_REQUESTS) as pool:
        records += list(pool.map(_fetch_daily, daily_months))
    return sorted(records, key=lambda r: r["month"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--start", default="2018-01")
    parser.add_argument("--end", default=str(config.SNAPSHOT_MONTH))
    args = parser.parse_args()
    df = pd.DataFrame(fetch_monthly_usd_vnd(pd.Period(args.start, "M"), pd.Period(args.end, "M")))
    print(df.groupby(["provider", "granularity"]).agg(months=("month", "count"), first=("month", "min"),
                                                      last=("month", "max")).to_string())


if __name__ == "__main__":
    main()
