"""Gọi các stored procedure của trang Khám phá (sql/serving/explore_procs.sql).

Toàn bộ logic lọc và tính toán nằm trong SQL. Python chỉ:
- kiểm tra bộ lọc chỉ chứa yếu tố/giá trị có thật (trả lỗi 400 rõ ràng thay vì âm thầm bỏ qua),
- đổi bộ lọc sang JSON làm tham số, gọi proc một lần và đọc mọi result set (1 round-trip, không N+1).
"""
import json

from src import config, db

CUSTOMER_LIST_LIMIT = 1000
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
    """Sắp xếp ổn định để cùng một bộ lọc luôn ra cùng một khoá cache."""
    if not isinstance(raw, dict):
        raise FilterError("filters phải là object {yếu_tố: [giá_trị, ...]}")
    allowed = {c["key"]: {v["value"] for v in c["values"]} for c in catalog}
    clean = {}
    for key, values in raw.items():
        if key not in allowed:
            raise FilterError(f"Yếu tố không hợp lệ: {key}")
        if not isinstance(values, list) or not values:
            continue
        bad = [v for v in values if str(v) not in allowed[key]]
        if bad:
            raise FilterError(f"Giá trị không hợp lệ cho {key}: {bad}")
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


def customers(filters: dict[str, list[str]]) -> list[dict]:
    return _call("EXEC mart.usp_explore_customers @filters = ?, @limit = ?",
                 (_to_json_param(filters), CUSTOMER_LIST_LIMIT))[0]


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
