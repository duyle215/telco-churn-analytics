"""Dashboard phân tích churn (thay cho Power BI): Flask phục vụ API JSON đọc từ TelcoDW.mart.

Chạy:  python -m src.dashboard.app   rồi mở http://127.0.0.1:5000

Tầng này không tự tính chỉ số; mọi phép tính nằm trong SQL (view mart, src/dashboard/explore.py).
Mô phỏng what-if ở frontend dùng đúng công thức của sql/analysis/07_whatif_contract.sql.
"""
import csv
import io
import json
import threading
import time
from collections import OrderedDict

from flask import Flask, Response, abort, jsonify, render_template, request

from src import config, db
from src.dashboard import explore

QUERIES = {
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
}
CACHE_MAX_ENTRIES = 300
BATCH_CHECK_SECONDS = 5

app = Flask(__name__)


class BatchCache:
    """Cache theo batch ETL: dữ liệu chỉ đổi khi ETL chạy lại, nên batch mới thì bỏ toàn bộ cache cũ.

    batch_id được kiểm tra lại tối đa mỗi BATCH_CHECK_SECONDS giây, để request thường không tốn thêm
    một round-trip chỉ để hỏi "đã có batch mới chưa".
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._data: OrderedDict = OrderedDict()
        self._batch, self._checked_at = None, 0.0

    def _current_batch(self) -> str:
        now = time.monotonic()
        if now - self._checked_at > BATCH_CHECK_SECONDS:
            with db.connect(config.DW_DB) as conn:
                row = conn.cursor().execute(
                    "SELECT TOP (1) CAST(batch_id AS NVARCHAR(36)) FROM mart.dq_check_results "
                    "ORDER BY checked_at DESC, dq_id DESC").fetchone()
            batch = row[0] if row else "none"
            with self._lock:
                if batch != self._batch:
                    self._data.clear()
                self._batch, self._checked_at = batch, now
        return self._batch

    def get(self, key: tuple, loader):
        full_key = (self._current_batch(), *key)
        with self._lock:
            if full_key in self._data:
                self._data.move_to_end(full_key)
                return self._data[full_key]
        value = loader()
        with self._lock:
            self._data[full_key] = value
            while len(self._data) > CACHE_MAX_ENTRIES:
                self._data.popitem(last=False)
        return value


cache = BatchCache()


def _fetch(sql: str) -> list[dict]:
    with db.connect(config.DW_DB) as conn:
        cur = conn.cursor()
        cur.execute(sql)
        cols = [c[0] for c in cur.description]
        return [{c: db.to_json_value(v) for c, v in zip(cols, row)} for row in cur.fetchall()]


def _request_filters() -> dict:
    body = request.get_json(silent=True) or {}
    catalog = cache.get(("factors",), explore.factor_catalog)
    try:
        return explore.validate_filters(body.get("filters", {}), catalog)
    except explore.FilterError as exc:
        abort(400, str(exc))


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/meta")
def meta():
    rows = _fetch("""
        SELECT TOP (1) CAST(batch_id AS NVARCHAR(36)) AS batch_id, finished_at, message
        FROM dbo.etl_log WHERE layer = 'pipeline' AND status = 'SUCCESS' ORDER BY started_at DESC""")
    return jsonify({
        "snapshot_date": config.SNAPSHOT_DATE.strftime("%Y-%m-%d"),
        "analysis_window": [str(config.CHURN_WINDOW_START), str(config.SNAPSHOT_MONTH)],
        "last_etl": rows[0] if rows else None,
    })


@app.get("/api/factors")
def factors():
    return jsonify(cache.get(("factors",), explore.factor_catalog))


@app.post("/api/explore")
def explore_data():
    filters = _request_filters()
    key = ("explore", json.dumps(filters, sort_keys=True))
    return jsonify(cache.get(key, lambda: explore.explore(filters)))


@app.post("/api/explore/customers")
def explore_customers():
    """Một trang danh sách khách: lọc / tìm / sắp xếp / chia trang đều chạy trong SQL, trả về đúng 1 trang."""
    filters, params = _request_filters(), _list_params()
    key = ("customers", json.dumps(filters, sort_keys=True), json.dumps(params, sort_keys=True))
    return jsonify(cache.get(key, lambda: explore.customers(filters, params)))


CSV_COLUMNS = [("customer_id", "Mã khách"), ("contract_type", "Hợp đồng"), ("internet_service", "Internet"),
               ("tenure_months", "Gắn bó (tháng)"), ("current_mrr_usd", "Cước/tháng (USD)"),
               ("billing_tickets", "Khiếu nại hoá đơn"), ("tickets", "Ticket"), ("late_payment_rate", "Tỷ lệ trả trễ"),
               ("tech_support", "Hỗ trợ KT"), ("addon_count", "Dịch vụ kèm"), ("payment_method", "Thanh toán")]


@app.post("/api/explore/customers.csv")
def explore_customers_csv():
    """File CSV do server tạo: đúng những khách đang khớp bộ lọc, không giới hạn theo trang."""
    filters, params = _request_filters(), _list_params()
    rows = explore.customers(filters, params, export=True)["rows"]
    out = io.StringIO()
    writer = csv.writer(out)
    writer.writerow([label for _, label in CSV_COLUMNS])
    writer.writerows([[r[k] for k, _ in CSV_COLUMNS] for r in rows])
    # BOM để Excel mở đúng tiếng Việt.
    return Response("\ufeff" + out.getvalue(), content_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f"attachment; filename=khach_can_cham_soc_{len(rows)}.csv"})


def _list_params() -> dict:
    try:
        return explore.validate_list_params(request.get_json(silent=True) or {})
    except explore.FilterError as exc:
        abort(400, str(exc))


@app.get("/api/<name>")
def dataset(name: str):
    if name not in QUERIES:
        abort(404)
    return jsonify(cache.get((name,), lambda: _fetch(QUERIES[name])))


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=False)
