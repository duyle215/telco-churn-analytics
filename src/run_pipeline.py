"""Run the whole pipeline from scratch: generate sources -> load stg -> ETL clean/mart + data quality.

Run:
  python -m src.run_pipeline           # re-run everything, keeping the etl_log history
  python -m src.run_pipeline --fresh   # drop TelcoDW and rebuild from zero

Afterwards: python -m src.dashboard.app  then open http://127.0.0.1:5000
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
    parser.add_argument("--fresh", action="store_true", help="Drop TelcoDW before running (loses etl_log history)")
    args = parser.parse_args()

    steps = []
    if args.fresh:
        steps.append(("Drop TelcoDW", drop_warehouse))
    steps += [
        ("Stage 1: generate source data", generate_sources.main),
        ("Stage 2: load stg", load_staging.main),
        # Always rebuild the clean/mart tables so a from-scratch run matches the latest DDL.
        ("Stages 3-4: ETL clean/mart, data quality, views", lambda: run_etl.run_all(rebuild=True)),
    ]
    started = time.perf_counter()
    for title, step in steps:
        print(f"\n######## {title}")
        t0 = time.perf_counter()
        step()
        print(f"-------- done in {time.perf_counter() - t0:.1f} s")
    print(f"\nPipeline finished in {time.perf_counter() - started:.1f} s. Dashboard: python -m src.dashboard.app")


if __name__ == "__main__":
    main()
