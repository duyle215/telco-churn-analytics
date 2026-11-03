"""Log each ETL step to dbo.etl_log.

Uses its own autocommit connection: when a load step fails and its data transaction is rolled back,
the FAILED log row still remains for investigation.
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
        # Deliberately broad: any error must leave a FAILED row, and it is always re-raised to the caller.
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
