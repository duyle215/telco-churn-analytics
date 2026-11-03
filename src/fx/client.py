"""Fetch monthly USD -> VND exchange rates from free public APIs (no API key needed).

Sources:
1. fawazahmed0/exchange-api (via the jsdelivr CDN, pages.dev mirror): daily rates,
   history only from 2024-03-02. Takes the rate of the first day with data in the month.
2. World Bank, indicator PA.NUS.FCRF (official rate, annual average): used for months
   before 2024-03 because source 1 has none. Every month of a year gets the same annual average.

No fallback to made-up data: if an API fails, an error is raised so the load step records FAILED
in etl_log, instead of silently loading a number that cannot be traced to a source.
Each record keeps provider and granularity so the DW and reports know where a number came from.

Try it:  python -m src.fx.client --start 2018-01 --end 2025-12
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
    # The second URL is the official mirror of the same dataset, not a different source.
    for template in DAILY_API_URLS:
        try:
            resp = requests.get(template.format(date=rate_date), timeout=TIMEOUT_SECONDS)
            resp.raise_for_status()
            payload = resp.json()
            return {"month": str(month), "rate_date": payload["date"], "usd_vnd": payload["usd"]["vnd"],
                    "provider": "fawazahmed0-currency-api", "granularity": "daily"}
        except (requests.RequestException, KeyError, ValueError) as exc:
            last_error = exc
    raise ConnectionError(f"Could not fetch the exchange rate for {rate_date}: {last_error}")


def _fetch_world_bank(months: list[pd.Period]) -> list[dict]:
    years = sorted({m.year for m in months})
    resp = requests.get(WORLD_BANK_URL.format(start=years[0], end=years[-1]), timeout=TIMEOUT_SECONDS)
    resp.raise_for_status()
    # The World Bank response looks like [metadata, [records]].
    annual = {int(r["date"]): r["value"] for r in resp.json()[1] if r["value"] is not None}
    missing = sorted(set(years) - set(annual))
    if missing:
        raise ConnectionError(f"World Bank has no data yet for years {missing}")
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
