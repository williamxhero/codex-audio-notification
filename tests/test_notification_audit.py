from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
AUDIT_HELPER_PATH = REPOSITORY_ROOT / "hooks" / "notification_audit.py"
SPEC = importlib.util.spec_from_file_location("notification_audit", AUDIT_HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = AUDIT
SPEC.loader.exec_module(AUDIT)


class NotificationAuditTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.log_directory = Path(self.temporary_directory.name) / "logs"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def make_record(self, turn_id: str) -> dict[str, object]:
        return AUDIT.build_audit_record(
            event_type="agent-turn-complete",
            thread_id="thread-id",
            turn_id=turn_id,
            cwd=r"D:\WILL\STOCK\MarketHub2",
            source="payload",
            profile="codex",
            decision="silence-unknown",
            reason="thread-not-registered",
            prefix_played=False,
            title_played=False,
            timestamp="2026-08-23T09:36:58.000Z",
        )

    def read_all_records(self) -> list[dict[str, object]]:
        records = []
        for log_path in sorted(self.log_directory.glob("notification-audit.jsonl*")):
            if log_path.suffix == ".lock":
                continue
            for line in log_path.read_text(encoding="utf-8").splitlines():
                records.append(json.loads(line))
        return records

    def test_written_lines_are_json_with_only_allowlisted_fields(self) -> None:
        record = self.make_record("turn-safe-fields")
        record["prompt"] = "must never be logged"
        record["fullPayload"] = {"input-messages": ["private"]}

        self.assertTrue(AUDIT.write_audit_record(self.log_directory, record))

        records = self.read_all_records()
        self.assertEqual(1, len(records))
        self.assertEqual(AUDIT.AUDIT_FIELDS, set(records[0]))
        self.assertNotIn("must never be logged", json.dumps(records[0]))

    def test_rotation_keeps_current_log_and_three_backups(self) -> None:
        for index in range(40):
            self.assertTrue(
                AUDIT.write_audit_record(
                    self.log_directory,
                    self.make_record(f"rotation-{index:02d}"),
                    max_bytes=900,
                    backup_count=3,
                )
            )

        log_files = sorted(self.log_directory.glob("notification-audit.jsonl*"))
        self.assertLessEqual(len(log_files), 4)
        self.assertLessEqual(sum(path.stat().st_size for path in log_files), 3600)
        self.assertTrue(all(path.stat().st_size <= 900 for path in log_files))
        self.assertTrue((self.log_directory / AUDIT.LOG_FILENAME).is_file())
        self.assertFalse(
            (self.log_directory / f"{AUDIT.LOG_FILENAME}.lock").exists()
        )
        self.assertTrue(self.read_all_records())

    def test_concurrent_writes_remain_line_delimited_json(self) -> None:
        def write(index: int) -> bool:
            return AUDIT.write_audit_record(
                self.log_directory,
                self.make_record(f"concurrent-{index:02d}"),
            )

        with ThreadPoolExecutor(max_workers=12) as executor:
            results = list(executor.map(write, range(40)))

        self.assertTrue(all(results))
        records = self.read_all_records()
        self.assertEqual(40, len(records))
        self.assertEqual(
            {f"concurrent-{index:02d}" for index in range(40)},
            {record["turnId"] for record in records},
        )


if __name__ == "__main__":
    unittest.main()
