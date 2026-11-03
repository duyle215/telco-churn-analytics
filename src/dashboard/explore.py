"""Calls the stored procedures behind the Explore page (sql/serving/explore_procs.sql).

All filtering and calculation logic lives in SQL. Python only:
- checks that filters only contain real factors/values (clear 400 error instead of silently ignoring them),
- turns the filters into a JSON parameter, calls the proc once and reads every result set (1 round trip, no N+1).
"""
import json

from src import config, db

EXPLORE_RESULT_SETS = ["kpi", "breakdown", "trend", "tickets", "retention", "retention_base"]


class FilterError(ValueError):
    pass


def factor_catalog() -> list[dict]:
    rows = _call("EXEC mart.usp_explore_factors")[0]
    catalog: dict[str, dict] = {}
    for r in rows:
        entry = catalog.setdefault(r["factor_key"], {"key": r["factor_key"], "label": r["factor_label"], "values": []})
        entry["values"].append({"value": r["value"], "customers": r["customers"]})
    return list(catalog.values())


def validate_filters(raw, catalog: list[dict]) -> dict[str, list[str]]:
    """Stable ordering so the same filters always produce the same cache key."""
    if not isinstance(raw, dict):
        raise FilterError("filters must be an object {factor: [value, ...]}")
    allowed = {c["key"]: {v["value"] for v in c["values"]} for c in catalog}
    clean = {}
    for key, values in raw.items():
        if key not in allowed:
            raise FilterError(f"Invalid factor: {key}")
        if not isinstance(values, list) or not values:
            continue
        bad = [v for v in values if str(v) not in allowed[key]]
        if bad:
            raise FilterError(f"Invalid value for {key}: {bad}")
        clean[key] = sorted({str(v) for v in values})
    return dict(sorted(clean.items()))


def _to_json_param(filters: dict[str, list[str]]) -> str:
    return json.dumps([{"factor": k, "value": v} for k, values in filters.items() for v in values], ensure_ascii=False)


def explore(filters: dict[str, list[str]]) -> dict:
    result_sets = _call("EXEC mart.usp_explore @filters = ?", (_to_json_param(filters),))
    data = dict(zip(EXPLORE_RESULT_SETS, result_sets))
    data["kpi"] = data["kpi"][0]
    data["filters"] = filters
    return data


QUICK_FILTERS = {"mrr", "bill", "late", "notech", "new"}
SORT_KEYS = {"customer_id", "contract_type", "internet_service", "payment_method", "tech_support", "tenure_months",
             "current_mrr_usd", "tickets", "billing_tickets", "late_payment_rate", "addon_count"}
PAGE_SIZE_MAX = 200


def validate_list_params(body: dict) -> dict:
    """Customer list parameters: only values from the allow-lists (the proc uses them in CASE, no dynamic SQL)."""
    quick = sorted({str(q) for q in body.get("quick", [])})
    if not set(quick) <= QUICK_FILTERS:
        raise FilterError(f"Invalid quick filter: {sorted(set(quick) - QUICK_FILTERS)}")
    sort_key = body.get("sort", "current_mrr_usd")
    if sort_key not in SORT_KEYS:
        raise FilterError(f"Cannot sort by column: {sort_key}")
    try:
        page, page_size = int(body.get("page", 0)), int(body.get("page_size", 50))
    except (TypeError, ValueError) as exc:
        raise FilterError("page/page_size must be numbers") from exc
    if page < 0 or not 0 < page_size <= PAGE_SIZE_MAX:
        raise FilterError(f"page >= 0 and 0 < page_size <= {PAGE_SIZE_MAX}")
    return {"quick": quick, "search": str(body.get("search", ""))[:50], "sort": sort_key,
            "desc": bool(body.get("desc", True)), "page": page, "page_size": page_size}


def customers(filters: dict[str, list[str]], params: dict, export: bool = False) -> dict:
    """One page of the list (or every matching row when exporting) + totals, computed entirely in SQL Server."""
    meta, rows = _call(
        "EXEC mart.usp_explore_customers @filters = ?, @quick = ?, @search = ?, @sort_key = ?, "
        "@sort_desc = ?, @page = ?, @page_size = ?",
        (_to_json_param(filters), json.dumps(params["quick"]), params["search"] or None, params["sort"],
         1 if params["desc"] else 0, 0 if export else params["page"], 0 if export else params["page_size"]))
    return {**meta[0], "page": params["page"], "page_size": params["page_size"], "rows": rows}


def _call(sql: str, params: tuple = ()) -> list[list[dict]]:
    out = []
    with db.connect(config.DW_DB) as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        while True:
            if cur.description:
                cols = [c[0] for c in cur.description]
                out.append([{c: db.to_json_value(v) for c, v in zip(cols, row)} for row in cur.fetchall()])
            if not cur.nextset():
                break
    return out
