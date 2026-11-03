"""Ghi nhật ký từng bước ETL vào dbo.etl_log.

Dùng kết nối autocommit riêng: khi bước nạp lỗi và transaction dữ liệu bị rollback,
dòng log FAILED vẫn còn lại để điều tra.
"""
import uuid
from contextlib import contextmanager
from dataclasses import dataclass

from src import config, db


@dataclass
class StepResult:
    rows_read: int = 0
    rows_written: int = 0
    message: str | None = None


class EtlLogger:
    def __init__(self, layer: str):
        self.layer = layer
        self.batch_id = str(uuid.uuid4())
        self._conn = db.connect(config.DW_DB, autocommit=True)

    def close(self) -> None:
        self._conn.close()

    @contextmanager
    def step(self, step_name: str, object_name: str | None = None, source_system: str | None = None):
        cur = self._conn.cursor()
        log_id = cur.execute(
            "INSERT INTO dbo.etl_log (batch_id, layer, step_name, object_name, source_system, status, started_at) "
            "OUTPUT INSERTED.log_id VALUES (?, ?, ?, ?, ?, 'RUNNING', SYSDATETIME())",
            self.batch_id, self.layer, step_name, object_name, source_system,
        ).fetchone()[0]
        result = StepResult()
        try:
            yield result
        # Bắt rộng có chủ đích: bất kỳ lỗi nào cũng phải để lại dòng FAILED, và luôn ném lại cho nơi gọi.
        except Exception as exc:
            self._finish(log_id, "FAILED", result, f"{type(exc).__name__}: {exc}"[:4000])
            raise
        self._finish(log_id, "SUCCESS", result, result.message)

    def _finish(self, log_id: int, status: str, result: StepResult, message: str | None) -> None:
        self._conn.cursor().execute(
            "UPDATE dbo.etl_log SET status = ?, rows_read = ?, rows_written = ?, message = ?, "
            "finished_at = SYSDATETIME() WHERE log_id = ?",
            status, result.rows_read, result.rows_written, message, log_id,
        )
