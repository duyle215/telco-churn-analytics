"""Tiện ích kết nối SQL Server dùng chung cho các bước sinh dữ liệu và nạp DW."""
import datetime as dt
import decimal
import re
from pathlib import Path

import numpy as np
import pandas as pd
import pyodbc

from src import config


def connect(database: str = "master", autocommit: bool = False) -> pyodbc.Connection:
    conn_str = (
        f"DRIVER={{{config.SQL_DRIVER}}};SERVER={config.SQL_SERVER};"
        f"DATABASE={database};Trusted_Connection=yes;"
    )
    return pyodbc.connect(conn_str, autocommit=autocommit)


def _check_db_name(name: str) -> None:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        raise ValueError(f"Tên database không hợp lệ: {name}")


def create_database_if_missing(name: str) -> None:
    """Dùng cho kho dữ liệu: không bao giờ drop vì etl_log cần giữ lịch sử các lần chạy."""
    _check_db_name(name)
    with connect("master", autocommit=True) as conn:
        conn.cursor().execute(f"IF DB_ID('{name}') IS NULL CREATE DATABASE [{name}]")


def recreate_database(name: str) -> None:
    """Xoá và tạo lại database nguồn mô phỏng để script sinh dữ liệu chạy lại luôn ra cùng kết quả."""
    _check_db_name(name)
    with connect("master", autocommit=True) as conn:
        cur = conn.cursor()
        # SINGLE_USER để ngắt các phiên SSMS/Power BI đang mở, nếu không DROP sẽ bị chặn.
        cur.execute(
            f"IF DB_ID('{name}') IS NOT NULL BEGIN "
            f"ALTER DATABASE [{name}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
            f"DROP DATABASE [{name}]; END"
        )
        cur.execute(f"CREATE DATABASE [{name}]")


def run_sql_file(conn: pyodbc.Connection, path: Path) -> None:
    """Chạy file .sql có nhiều batch ngăn bởi GO (pyodbc không hiểu GO, đó là lệnh của sqlcmd/SSMS)."""
    script = path.read_text(encoding="utf-8")
    batches = re.split(r"^\s*GO\s*$", script, flags=re.IGNORECASE | re.MULTILINE)
    cur = conn.cursor()
    for batch in batches:
        if batch.strip():
            cur.execute(batch)
    conn.commit()


def insert_rows(conn: pyodbc.Connection, table: str, columns: list[str], rows: list[tuple],
                chunk_size: int = 20000) -> int:
    """Ghi nhiều dòng bằng fast_executemany. Không commit: transaction do nơi gọi quản lý."""
    if not rows:
        return 0
    col_sql = ", ".join(f"[{c}]" for c in columns)
    sql = f"INSERT INTO {table} ({col_sql}) VALUES ({', '.join('?' for _ in columns)})"
    cur = conn.cursor()
    cur.fast_executemany = True
    for start in range(0, len(rows), chunk_size):
        cur.executemany(sql, rows[start:start + chunk_size])
    return len(rows)


def bulk_insert(conn: pyodbc.Connection, table: str, df: pd.DataFrame, chunk_size: int = 20000) -> int:
    # pyodbc không nhận NaN/NaT/numpy scalar; đổi về None và kiểu Python thuần.
    clean = df.astype(object).where(pd.notna(df), None)
    rows = [tuple(_to_python(v) for v in row) for row in clean.itertuples(index=False, name=None)]
    written = insert_rows(conn, table, list(df.columns), rows, chunk_size)
    conn.commit()
    return written


def _to_python(value):
    if isinstance(value, np.generic):
        return value.item()
    if isinstance(value, pd.Timestamp):
        return value.to_pydatetime()
    return value


def to_json_value(value):
    """Đổi kiểu trả về của pyodbc (Decimal, date) sang kiểu JSON được."""
    if isinstance(value, decimal.Decimal):
        return float(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    return value
