"""Dashboard phân tích churn (thay cho Power BI): Flask phục vụ API JSON đọc từ các view mart.

Chạy:  python -m src.dashboard.app   rồi mở http://127.0.0.1:5000

Mọi con số đều lấy từ view trong TelcoDW.mart; tầng này không tính lại chỉ số nào
(trừ mô phỏng what-if ở frontend, dùng đúng công thức của sql/analysis/07_whatif_contract.sql).
"""
import datetime as dt
import decimal
import threading

from flask import Flask, abort, jsonify, render_template, request

from src import config, db

SEGMENT_CUSTOMER_LIMIT = 1000

QUERIES = {
    "kpi": "SELECT * FROM mart.v_kpi_monthly WHERE is_analysis_window = 1 ORDER BY date_key",
    "drivers": "SELECT * FROM mart.v_churn_drivers",
    "internet_contract": "SELECT * FROM mart.v_churn_internet_by_contract ORDER BY contract_sort, internet_service",
    "cohort": "SELECT * FROM mart.v_cohort_retention ORDER BY cohort_month, month_offset",
    "anomaly": "SELECT * FROM mart.v_anomaly_monthly ORDER BY metric, segment, date_key",
    "risk_segments": "SELECT * FROM mart.v_risk_segments ORDER BY expected_mrr_loss_usd DESC",
    "whatif_base": "SELECT * FROM mart.v_whatif_contract_base ORDER BY contract_sort",
    "dq_checks": "SELECT * FROM mart.v_dq_latest ORDER BY dq_id",
    "rejected": "SELECT * FROM mart.v_rejected_summary ORDER BY rejected_rows DESC",
    "etl_steps": """
        SELECT step_name, layer, status, rows_read, rows_written, started_at, finished_at,
               DATEDIFF(millisecond, started_at, finished_at) AS duration_ms, message
        FROM dbo.etl_log
        WHERE batch_id = (SELECT TOP (1) batch_id FROM dbo.etl_log WHERE layer = 'pipeline' AND status = 'SUCCESS'
                          ORDER BY started_at DESC)
        ORDER BY log_id""",
    "segment_customers": f"""
        SELECT TOP ({SEGMENT_CUSTOMER_LIMIT}) customer_id, tenure_months, tenure_group, current_mrr_usd,
               tickets, billing_tickets, late_payment_rate, tech_support, online_security, addon_count,
               payment_method, senior_citizen
        FROM mart.v_customer_profile
        WHERE risk_segment = ? AND customer_status = N'Active'
        ORDER BY current_mrr_usd DESC, tickets DESC""",
}

app = Flask(__name__)
_cache: dict = {}
_cache_lock = threading.Lock()


def _to_json_value(value):
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    return value


def _fetch(sql: str, params: tuple = ()) -> list[dict]:
    with db.connect(config.DW_DB) as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        cols = [c[0] for c in cur.description]
        return [{c: _to_json_value(v) for c, v in zip(cols, row)} for row in cur.fetchall()]


def _latest_batch() -> str:
    rows = _fetch("SELECT TOP (1) CAST(batch_id AS NVARCHAR(36)) AS batch_id FROM mart.dq_check_results "
                  "ORDER BY checked_at DESC, dq_id DESC")
    return rows[0]["batch_id"] if rows else "none"


def cached(name: str, params: tuple = ()) -> list[dict]:
    """Dữ liệu chỉ đổi khi ETL chạy lại, nên cache theo batch_id mới nhất thay vì theo thời gian."""
    key = (_latest_batch(), name, params)
    with _cache_lock:
        if key in _cache:
            return _cache[key]
    data = _fetch(QUERIES[name], params)
    with _cache_lock:
        stale = [k for k in _cache if k[0] != key[0]]
        for k in stale:
            del _cache[k]
        _cache[key] = data
    return data


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/meta")
def meta():
    pipeline = _fetch("""
        SELECT TOP (1) CAST(batch_id AS NVARCHAR(36)) AS batch_id, finished_at, message
        FROM dbo.etl_log WHERE layer = 'pipeline' AND status = 'SUCCESS' ORDER BY started_at DESC""")
    return jsonify({
        "snapshot_date": config.SNAPSHOT_DATE.strftime("%Y-%m-%d"),
        "analysis_window": [str(config.CHURN_WINDOW_START), str(config.SNAPSHOT_MONTH)],
        "last_etl": pipeline[0] if pipeline else None,
    })


@app.get("/api/<name>")
def dataset(name: str):
    if name not in QUERIES or name == "segment_customers":
        abort(404)
    return jsonify(cached(name))


@app.get("/api/segment_customers")
def segment_customers():
    segment = request.args.get("segment", "")
    if not segment:
        abort(400, "Thiếu tham số segment")
    return jsonify({"limit": SEGMENT_CUSTOMER_LIMIT, "rows": cached("segment_customers", (segment,))})


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
