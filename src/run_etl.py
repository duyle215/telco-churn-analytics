"""GIAI ĐOẠN 3: deploy và chạy ETL stg -> clean -> mart + kiểm tra chất lượng dữ liệu.

Chạy:
  python -m src.run_etl --rebuild   # tạo lại bảng clean/mart rồi chạy (lần đầu, hoặc khi đổi DDL)
  python -m src.run_etl             # chỉ chạy lại stored procedure (idempotent)

Toàn bộ logic nằm trong stored procedure; script này chỉ deploy file SQL, đồng bộ tham số
từ src/config.py vào dbo.etl_config và gọi dbo.usp_run_etl.
"""
import argparse

from src import config, db

DDL_REBUILD_FILES = ["03_clean_tables.sql", "04_mart_tables.sql"]
# Thứ tự deploy: hàm tiện ích trước (view cần), rồi view (proc nạp snapshot đọc cột của view lúc biên dịch),
# cuối cùng là các proc ETL và data quality.
CODE_ORDER = ["etl/00_helpers.sql", "views/*.sql", "etl/[1-9]*.sql", "quality/*.sql", "serving/*.sql"]


def sync_config(conn) -> None:
    values = [
        ("snapshot_date", config.SNAPSHOT_DATE.strftime("%Y-%m-%d"), "Ngày chụp dữ liệu; khách chưa rời đi được tính tới tháng này"),
        ("analysis_window_start", config.CHURN_WINDOW_START.start_time.strftime("%Y-%m-%d"),
         "Đầu cửa sổ phân tích churn; trước mốc này không có dữ liệu khách rời đi"),
    ]
    cur = conn.cursor()
    for key, value, desc in values:
        cur.execute(
            "MERGE dbo.etl_config AS t USING (SELECT ? AS k, ? AS v, ? AS d) s ON t.config_key = s.k "
            "WHEN MATCHED THEN UPDATE SET config_value = s.v, description = s.d "
            "WHEN NOT MATCHED THEN INSERT (config_key, config_value, description) VALUES (s.k, s.v, s.d);",
            key, value, desc)
    conn.commit()


def deploy(rebuild: bool) -> None:
    with db.connect(config.DW_DB) as conn:
        db.run_sql_file(conn, config.SQL_DIR / "ddl" / "01_schemas_and_etl_log.sql")
        tables_missing = conn.cursor().execute("SELECT OBJECT_ID('mart.fact_billing')").fetchone()[0] is None
        if rebuild or tables_missing:
            for name in DDL_REBUILD_FILES:
                db.run_sql_file(conn, config.SQL_DIR / "ddl" / name)
        for pattern in CODE_ORDER:
            for path in sorted(config.SQL_DIR.glob(pattern)):
                db.run_sql_file(conn, path)
        sync_config(conn)


def run() -> str:
    # autocommit bắt buộc: các proc tự quản lý transaction; nếu pyodbc bọc thêm một transaction
    # ngoài cùng thì lỗi ở bước cuối sẽ rollback cả các dòng etl_log của những bước trước.
    with db.connect(config.DW_DB, autocommit=True) as conn:
        cur = conn.cursor()
        cur.execute("EXEC dbo.usp_run_etl")
        while cur.description is None:
            cur.nextset()
        return str(cur.fetchone()[0])


def print_report(batch_id: str) -> None:
    with db.connect(config.DW_DB) as conn:
        cur = conn.cursor()
        print(f"== etl_log batch {batch_id}")
        for step, status, r_read, r_written, ms, message in cur.execute(
                "SELECT step_name, status, rows_read, rows_written, DATEDIFF(millisecond, started_at, finished_at), message "
                "FROM dbo.etl_log WHERE batch_id = ? ORDER BY log_id", batch_id).fetchall():
            print(f"  {step:<34} {status:<8} read={r_read or 0:>8,} written={r_written or 0:>8,} {ms or 0:>7,} ms  {message or ''}")
        print("== data quality")
        for check_id, status, before, after, rejected, note in cur.execute(
                "SELECT check_id, status, value_before, value_after, value_rejected, note FROM mart.dq_check_results "
                "WHERE batch_id = ? ORDER BY dq_id", batch_id).fetchall():
            fmt = lambda v: "" if v is None else f"{v:,.2f}".rstrip("0").rstrip(".")
            print(f"  {status:<5} {check_id:<32} before={fmt(before):>14} after={fmt(after):>14} "
                  f"rejected={fmt(rejected):>8}  {note or ''}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rebuild", action="store_true", help="Tạo lại bảng clean/mart trước khi chạy")
    args = parser.parse_args()
    run_all(args.rebuild)


def run_all(rebuild: bool) -> None:
    deploy(rebuild)
    print_report(run())


if __name__ == "__main__":
    main()
