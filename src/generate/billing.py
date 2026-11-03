"""Generate "clean" invoices and payments (before error injection) from the customer timeline."""
import numpy as np
import pandas as pd

from src import config

# Monthly usage variation of the charge (overage, extra fees...).
USAGE_NOISE_SD = 0.02
PAYMENT_TERM_DAYS = 15

# Automatic payment is almost never late; manual payment (check) is late more often.
BASE_LATE_PROBABILITY = {
    "Electronic check": 0.12,
    "Mailed check": 0.10,
    "Bank transfer (automatic)": 0.03,
    "Credit card (automatic)": 0.03,
}
CHURNER_LATE_MULTIPLIER = 2.0
# Late payments jump in the last 3 months before leaving: an early-warning signal
# the analysis can find. It is simulated, so it is not reported as a finding.
PRE_CHURN_LATE_MULTIPLIER = 4.0
PRE_CHURN_WINDOW_MONTHS = 3
MAX_LATE_PROBABILITY = 0.85
UNPAID_FINAL_INVOICE_PROBABILITY = 0.25


def build_invoices(timeline: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    billed = timeline[timeline["tenure"] > 0]
    inv = billed.loc[billed.index.repeat(billed["tenure"]), [
        "customer_id", "first_billed_month", "last_billed_month", "is_fiber", "is_churned",
        "monthly_charges", "price_before_event", "payment_method",
    ]].reset_index(drop=True)
    inv["billing_month"] = inv["first_billed_month"] + inv.groupby("customer_id").cumcount()

    before_event = inv["billing_month"] < config.FIBER_PRICE_EVENT_MONTH
    list_price = np.where(before_event, inv["price_before_event"], inv["monthly_charges"])
    inv["amount_usd"] = (list_price * (1 + rng.normal(0, USAGE_NOISE_SD, len(inv)))).round(2)

    inv["invoice_date"] = inv["billing_month"].dt.end_time.dt.normalize()
    inv["due_date"] = inv["invoice_date"] + pd.Timedelta(days=PAYMENT_TERM_DAYS)
    inv["months_to_last"] = inv["last_billed_month"].array.asi8 - inv["billing_month"].array.asi8

    inv = inv.sort_values(["billing_month", "customer_id"]).reset_index(drop=True)
    seq = inv.groupby("billing_month").cumcount() + 1
    inv["invoice_id"] = "INV" + inv["billing_month"].dt.strftime("%Y%m") + "-" + seq.astype(str).str.zfill(5)
    return inv


def build_payments(invoices: pd.DataFrame, rng: np.random.Generator) -> pd.DataFrame:
    inv = invoices
    p_late = inv["payment_method"].map(BASE_LATE_PROBABILITY).to_numpy()
    p_late = np.where(inv["is_churned"], p_late * CHURNER_LATE_MULTIPLIER, p_late)
    pre_churn = inv["is_churned"] & (inv["months_to_last"] < PRE_CHURN_WINDOW_MONTHS)
    p_late = np.minimum(np.where(pre_churn, p_late * PRE_CHURN_LATE_MULTIPLIER, p_late), MAX_LATE_PROBABILITY)
    is_late = rng.random(len(inv)) < p_late

    on_time_days = rng.integers(1, PAYMENT_TERM_DAYS + 1, len(inv))
    late_days = np.minimum(rng.geometric(0.08, len(inv)), 60)
    payment_date = np.where(
        is_late,
        inv["due_date"] + pd.to_timedelta(late_days, unit="D"),
        inv["invoice_date"] + pd.to_timedelta(on_time_days, unit="D"),
    )

    pay = pd.DataFrame({
        "invoice_id": inv["invoice_id"],
        "customer_id": inv["customer_id"],
        "payment_date": pd.to_datetime(payment_date),
        "amount_usd": inv["amount_usd"],
        "payment_method": inv["payment_method"],
    })

    # Leaving customers often skip their final invoice; invoices due after the snapshot naturally have no payment yet.
    final_unpaid = (inv["is_churned"] & (inv["months_to_last"] == 0)
                    & (rng.random(len(inv)) < UNPAID_FINAL_INVOICE_PROBABILITY))
    pay = pay[~final_unpaid & (pay["payment_date"] <= config.SNAPSHOT_DATE)]

    pay = pay.sort_values(["payment_date", "invoice_id"]).reset_index(drop=True)
    pay.insert(0, "payment_id", "PAY" + (pay.index + 1).astype(str).str.zfill(7))
    return pay
