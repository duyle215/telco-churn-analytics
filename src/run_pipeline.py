"""Chạy toàn bộ pipeline từ đầu: sinh nguồn -> nạp stg -> ETL clean/mart + data quality.

Chạy:
  python -m src.run_pipeline           # chạy lại toàn bộ, giữ lịch sử etl_log
  python -m src.run_pipeline --fresh   # xoá TelcoDW và dựng lại từ con số 0

Sau khi xong: python -m src.dashboard.app  rồi mở http://127.0.0.1:5000
"""
import argparse
import time

from src import config, db, generate_sources, load_staging, run_etl


def drop_warehouse() -> None:
    with db.connect("master", autocommit=True) as conn:
        conn.cursor().execute(
            f"IF DB_ID('{config.DW_DB}') IS NOT NULL BEGIN "
            f"ALTER DATABASE [{config.DW_DB}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
            f"DROP DATABASE [{config.DW_DB}]; END")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fresh", action="store_true", help="Xoá TelcoDW trước khi chạy (mất lịch sử etl_log)")
    args = parser.parse_args()

    steps = []
    if args.fresh:
        steps.append(("Xoá TelcoDW", drop_warehouse))
    steps += [
        ("Giai đoạn 1: sinh dữ liệu nguồn", generate_sources.main),
        ("Giai đoạn 2: nạp stg", load_staging.main),
        # Lần nào cũng dựng lại bảng clean/mart để bản chạy từ đầu luôn khớp DDL mới nhất.
        ("Giai đoạn 3-4: ETL clean/mart, data quality, view", lambda: run_etl.run_all(rebuild=True)),
    ]
    started = time.perf_counter()
    for title, step in steps:
        print(f"\n######## {title}")
        t0 = time.perf_counter()
        step()
        print(f"-------- xong sau {time.perf_counter() - t0:.1f} giây")
    print(f"\nPipeline hoàn tất sau {time.perf_counter() - started:.1f} giây. Dashboard: python -m src.dashboard.app")


if __name__ == "__main__":
    main()
