"""Deliberately inject realistic data errors into the sources, and record exactly how many of each.

Each function injects one error type and records it in ErrorLog, so the cleaning stage has an "answer key":
the number of errors found by the ETL must match the number injected here.
"""
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from src import config

YES_VARIANTS = ["Y", "yes", "1", "YES"]
NO_VARIANTS = ["N", "no", "0", "NO"]

# Different date formats from several entry screens / CRM software generations.
# MM/DD/YYYY is not used, to avoid cases that cannot be resolved (is 03/04 March or April?).
DATE_FORMATS = [("%Y-%m-%d", 0.70), ("%d/%m/%Y", 0.15), ("%Y%m%d", 0.10), ("%d-%b-%Y", 0.05)]
DATETIME_FORMATS = [("%Y-%m-%d %H:%M:%S", 0.78), ("%d/%m/%Y %H:%M", 0.15), ("%d-%b-%Y %I:%M %p", 0.07)]


@dataclass
class ErrorLog:
    entries: list[dict] = field(default_factory=list)

    def add(self, source_system: str, obj: str, column: str, error_type: str, rows: int, description: str):
        self.entries.append({"source_system": source_system, "object": obj, "column": column,
                             "error_type": error_type, "rows_affected": int(rows), "description": description})

    def extend(self, entries: list[dict]):
        self.entries.extend(entries)

    def to_frame(self) -> pd.DataFrame:
        df = pd.DataFrame(self.entries)
        df.insert(0, "error_id", range(1, len(df) + 1))
        return df


def duplicate_customers(customers: pd.DataFrame, rng: np.random.Generator, log: ErrorLog,
                        n_exact: int = 20, n_conflict: int = 25, n_conflict_with_space: int = 10) -> pd.DataFrame:
    """The old CRM has no primary key constraint, so a customer gets entered twice.

    - Exact duplicate: the clerk pressed save twice.
    - Conflicting duplicate: the record was re-entered later with updated information (newer updated_at);
      some also carry trailing whitespace in customer_id, so a raw GROUP BY customer_id will not catch them.
    """
    picked = rng.choice(customers.index, size=n_exact + n_conflict, replace=False)
    exact = customers.loc[picked[:n_exact]].copy()

    conflict = customers.loc[picked[n_exact:]].copy()
    conflict["dependents"] = np.where(conflict["dependents"].eq("Yes"), "No", "Yes")
    delay = pd.to_timedelta(rng.integers(30, 400, len(conflict)), unit="D")
    conflict["updated_at"] = (conflict["updated_at"] + delay).clip(upper=config.SNAPSHOT_DATE)
    conflict.iloc[:n_conflict_with_space, conflict.columns.get_loc("customer_id")] = (
        conflict["customer_id"].iloc[:n_conflict_with_space] + " ")

    log.add("crm", "src_crm.dbo.customers", "customer_id", "duplicate_key_exact", n_exact,
            "Exact duplicate record (entered twice)")
    log.add("crm", "src_crm.dbo.customers", "customer_id", "duplicate_key_conflicting", n_conflict,
            f"Duplicate record with a different dependents value and newer updated_at; {n_conflict_with_space} "
            "of these rows have trailing whitespace in customer_id")
    out = pd.concat([customers, exact, conflict], ignore_index=True)
    return out.sample(frac=1, random_state=int(rng.integers(1_000_000))).reset_index(drop=True)


def yes_no_variants(df: pd.DataFrame, column: str, rate: float, rng: np.random.Generator,
                    log: ErrorLog, source_system: str, obj: str) -> pd.DataFrame:
    eligible = df.index[df[column].isin(["Yes", "No"])]
    picked = rng.choice(eligible, size=int(len(eligible) * rate), replace=False)
    is_yes = df.loc[picked, column].eq("Yes").to_numpy()
    df.loc[picked, column] = np.where(is_yes, rng.choice(YES_VARIANTS, len(picked)),
                                      rng.choice(NO_VARIANTS, len(picked)))
    log.add(source_system, obj, column, "inconsistent_boolean", len(picked),
            "Yes/No values mixed with Y/yes/1/YES and N/no/0/NO")
    return df


def extra_whitespace(df: pd.DataFrame, column: str, n: int, rng: np.random.Generator,
                     log: ErrorLog, source_system: str, obj: str) -> pd.DataFrame:
    picked = rng.choice(df.index[df[column].notna()], size=n, replace=False)
    style = rng.integers(0, 3, n)
    values = df.loc[picked, column].astype(str).to_numpy()
    df.loc[picked, column] = np.select([style == 0, style == 1], [" " + values, values + " "], "  " + values + "  ")
    log.add(source_system, obj, column, "extra_whitespace", n, "Leading/trailing whitespace in the value")
    return df


def mixed_date_format(series: pd.Series, formats: list[tuple[str, float]], rng: np.random.Generator,
                      log: ErrorLog, source_system: str, obj: str) -> pd.Series:
    """Turn a date column into strings in several formats; log the rows not in the standard format (first in the list)."""
    choice = rng.choice(len(formats), size=len(series), p=[p for _, p in formats])
    out = pd.Series(pd.NA, index=series.index, dtype="object")
    counts = {}
    for i, (fmt, _) in enumerate(formats):
        mask = (choice == i) & series.notna().to_numpy()
        out[mask] = series[mask].dt.strftime(fmt)
        counts[fmt] = int(mask.sum())
    non_standard = sum(c for fmt, c in counts.items() if fmt != formats[0][0])
    detail = ", ".join(f"'{fmt}': {c}" for fmt, c in counts.items())
    log.add(source_system, obj, series.name, "mixed_date_format", non_standard,
            f"Dates stored as strings in several formats ({detail}); counted rows are those not in '{formats[0][0]}'")
    return out


def drop_outage_month(invoices: pd.DataFrame, payments: pd.DataFrame, log: ErrorLog):
    lost = invoices["billing_month"].eq(config.BILLING_OUTAGE_MONTH)
    lost_ids = set(invoices.loc[lost, "invoice_id"])
    lost_payments = payments["invoice_id"].isin(lost_ids)
    log.add("billing", "src_billing.dbo.invoices", "billing_month", "missing_period", int(lost.sum()),
            f"Billing system outage: no invoices generated for {config.BILLING_OUTAGE_MONTH}")
    log.add("billing", "src_billing.dbo.payments", "invoice_id", "missing_period", int(lost_payments.sum()),
            f"Payments for the {config.BILLING_OUTAGE_MONTH} invoices are missing too")
    return invoices[~lost].reset_index(drop=True), payments[~lost_payments].reset_index(drop=True)


def orphan_invoices(invoices: pd.DataFrame, payments: pd.DataFrame, crm_ids: set[str],
                    rng: np.random.Generator, log: ErrorLog, n_customers: int = 8):
    """Invoices for customers that do not exist in CRM (test accounts, customers deleted from CRM).

    The two systems are separate, so no foreign key prevents this.
    """
    letters = np.array(list("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
    fake_ids = []
    while len(fake_ids) < n_customers:
        cid = f"{rng.integers(1000, 10000)}-{''.join(rng.choice(letters, 5))}"
        if cid not in crm_ids and cid not in fake_ids:
            fake_ids.append(cid)

    rows = []
    for cid in fake_ids:
        start = pd.Period("2024-01", "M") + int(rng.integers(0, 18))
        price = round(float(rng.uniform(20, 105)), 2)
        for k in range(int(rng.integers(3, 10))):
            month = start + k
            if month == config.BILLING_OUTAGE_MONTH or month > config.SNAPSHOT_MONTH:
                continue
            rows.append({"customer_id": cid, "billing_month": month,
                         "amount_usd": round(price * (1 + rng.normal(0, 0.02)), 2)})
    orphan = pd.DataFrame(rows)
    orphan["invoice_date"] = orphan["billing_month"].dt.end_time.dt.normalize()
    orphan["due_date"] = orphan["invoice_date"] + pd.Timedelta(days=15)
    # 9xxxx range so the numbers do not collide with real invoice sequence numbers in the same month.
    seq = orphan.groupby("billing_month").cumcount() + 90001
    orphan["invoice_id"] = "INV" + orphan["billing_month"].dt.strftime("%Y%m") + "-" + seq.astype(str)

    orphan_pay = pd.DataFrame({
        "invoice_id": orphan["invoice_id"],
        "customer_id": orphan["customer_id"],
        "payment_date": orphan["invoice_date"] + pd.to_timedelta(rng.integers(1, 16, len(orphan)), unit="D"),
        "amount_usd": orphan["amount_usd"],
        "payment_method": "Credit card (automatic)",
    })
    orphan_pay = orphan_pay[orphan_pay["payment_date"] <= config.SNAPSHOT_DATE]
    last_seq = int(payments["payment_id"].str[3:].astype(int).max())
    orphan_pay.insert(0, "payment_id", ["PAY" + str(last_seq + i + 1).zfill(7) for i in range(len(orphan_pay))])

    log.add("billing", "src_billing.dbo.invoices", "customer_id", "orphan_key", len(orphan),
            f"Invoices for {n_customers} customer_id not found in CRM: {', '.join(fake_ids)}")
    log.add("billing", "src_billing.dbo.payments", "customer_id", "orphan_key", len(orphan_pay),
            "Payments of the orphan invoices above")
    return (pd.concat([invoices, orphan], ignore_index=True),
            pd.concat([payments, orphan_pay], ignore_index=True))


def invoice_amount_errors(invoices: pd.DataFrame, rng: np.random.Generator, log: ErrorLog,
                          n_negative: int = 120, n_null: int = 150) -> pd.DataFrame:
    """Negative amount from a sign entry error, and NULL amount from an integration error.

    The payments table still holds the correct amount, so cleaning can recover NULL amounts from payments.
    """
    picked = rng.choice(invoices.index, size=n_negative + n_null, replace=False)
    invoices.loc[picked[:n_negative], "amount_usd"] = -invoices.loc[picked[:n_negative], "amount_usd"]
    invoices.loc[picked[n_negative:], "amount_usd"] = np.nan
    log.add("billing", "src_billing.dbo.invoices", "amount_usd", "negative_amount", n_negative,
            "Amount sign flipped to negative by an entry error")
    log.add("billing", "src_billing.dbo.invoices", "amount_usd", "null_amount", n_null,
            "NULL amount from an integration error; payments still hold the correct amount")
    return invoices
