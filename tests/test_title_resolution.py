from __future__ import annotations

import importlib.util
import json
from contextlib import closing
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = REPOSITORY_ROOT / "hooks" / "generate-thread-title-audio.py"
SPEC = importlib.util.spec_from_file_location("generate_thread_title_audio", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
HELPER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = HELPER
SPEC.loader.exec_module(HELPER)


class TitleResolutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.codex_home = Path(self.temporary_directory.name)
        self.database_path = self.codex_home / "state_5.sqlite"
        with closing(sqlite3.connect(self.database_path)) as connection:
            connection.executescript(
                """
                CREATE TABLE threads (
                    id TEXT PRIMARY KEY,
                    name TEXT,
                    thread_source TEXT,
                    rollout_path TEXT,
                    source TEXT
                );
                CREATE TABLE thread_spawn_edges (child_thread_id TEXT);
                """
            )
            connection.commit()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def add_thread(self, thread_id: str, name: str | None) -> None:
        with closing(sqlite3.connect(self.database_path)) as connection:
            connection.execute(
                """
                INSERT INTO threads (id, name, thread_source, rollout_path, source)
                VALUES (?, ?, 'user', NULL, '{}')
                """,
                (thread_id, name),
            )
            connection.commit()

    def write_index_records(self, *records: object) -> None:
        with (self.codex_home / "session_index.jsonl").open(
            "w", encoding="utf-8", newline="\n"
        ) as index_file:
            for record in records:
                if isinstance(record, str):
                    index_file.write(record + "\n")
                else:
                    index_file.write(json.dumps(record) + "\n")

    def test_database_name_has_priority_over_session_index(self) -> None:
        thread_id = "thread-name-priority"
        self.add_thread(thread_id, "Database title")
        self.write_index_records(
            {"id": thread_id, "thread_name": "Index title"},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)

        self.assertIsNotNone(info)
        self.assertEqual("Database title", info.title)

    def test_null_database_name_falls_back_to_session_index(self) -> None:
        thread_id = "thread-null-fallback"
        self.add_thread(thread_id, None)
        self.write_index_records(
            {"id": thread_id, "thread_name": "Fallback title"},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)

        self.assertIsNotNone(info)
        self.assertEqual("Fallback title", info.title)

    def test_malformed_or_missing_index_is_ignored_safely(self) -> None:
        malformed_thread_id = "thread-malformed-index"
        self.add_thread(malformed_thread_id, None)
        self.write_index_records(
            "{not valid json",
            ["not", "an", "object"],
            {"id": malformed_thread_id, "thread_name": "Recovered title"},
            "also not json",
        )

        malformed_info = HELPER.resolve_thread(
            self.database_path, malformed_thread_id
        )

        self.assertIsNotNone(malformed_info)
        self.assertEqual("Recovered title", malformed_info.title)

        (self.codex_home / "session_index.jsonl").unlink()
        missing_thread_id = "thread-missing-index"
        self.add_thread(missing_thread_id, None)

        missing_info = HELPER.resolve_thread(self.database_path, missing_thread_id)

        self.assertIsNotNone(missing_info)
        self.assertIsNone(missing_info.title)

    def test_index_without_a_nonempty_matching_title_returns_none(self) -> None:
        thread_id = "thread-empty-index"
        self.add_thread(thread_id, None)
        self.write_index_records(
            {"id": "different-thread", "thread_name": "Different title"},
            {"id": thread_id, "thread_name": "  "},
            {"id": thread_id, "thread_name": None},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)

        self.assertIsNotNone(info)
        self.assertIsNone(info.title)

    def test_duplicate_records_use_the_last_valid_matching_title(self) -> None:
        thread_id = "thread-duplicate-index"
        self.add_thread(thread_id, None)
        self.write_index_records(
            {"id": thread_id, "thread_name": "First title"},
            {"id": thread_id, "thread_name": ""},
            {"id": thread_id, "thread_name": "Last valid title"},
            {"id": thread_id, "thread_name": 42},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)

        self.assertIsNotNone(info)
        self.assertEqual("Last valid title", info.title)

    def test_unknown_thread_is_silenced(self) -> None:
        decision = HELPER.notification_decision(
            None,
            "01a02df9-f1e0-7e81-8039-7eb93047022b",
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("silence-unknown", decision)

    def test_database_title_with_mute_marker_is_silenced(self) -> None:
        thread_id = "thread-muted-database-title"
        self.add_thread(thread_id, "Review release 🔇️ before shipping")

        info = HELPER.resolve_thread(self.database_path, thread_id)
        decision = HELPER.notification_decision(
            info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("silence-muted", decision)

    def test_index_fallback_title_with_mute_marker_is_silenced(self) -> None:
        thread_id = "thread-muted-index-title"
        self.add_thread(thread_id, None)
        self.write_index_records(
            {"id": thread_id, "thread_name": "Earlier title"},
            {"id": thread_id, "thread_name": "🔇 Muted fallback title"},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)
        decision = HELPER.notification_decision(
            info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("🔇 Muted fallback title", info.title)
        self.assertEqual("silence-muted", decision)

    def test_normal_title_is_not_silenced_as_muted(self) -> None:
        thread_id = "thread-normal-title"
        self.add_thread(thread_id, "Normal notification title")

        info = HELPER.resolve_thread(self.database_path, thread_id)
        decision = HELPER.notification_decision(
            info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("play", decision)

    def test_database_rename_without_marker_overrides_muted_index_history(self) -> None:
        thread_id = "thread-renamed-unmuted"
        self.add_thread(thread_id, "🔇 Muted database title")
        self.write_index_records(
            {"id": thread_id, "thread_name": "🔇 Old muted index title"},
        )

        muted_info = HELPER.resolve_thread(self.database_path, thread_id)
        muted_decision = HELPER.notification_decision(
            muted_info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )
        self.assertEqual("silence-muted", muted_decision)

        with closing(sqlite3.connect(self.database_path)) as connection:
            connection.execute(
                "UPDATE threads SET name = ? WHERE id = ?",
                ("Renamed audible title", thread_id),
            )
            connection.commit()

        renamed_info = HELPER.resolve_thread(self.database_path, thread_id)
        renamed_decision = HELPER.notification_decision(
            renamed_info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("Renamed audible title", renamed_info.title)
        self.assertEqual("play", renamed_decision)

    def test_latest_index_rename_without_marker_restores_play(self) -> None:
        thread_id = "thread-index-renamed-unmuted"
        self.add_thread(thread_id, None)
        self.write_index_records(
            {"id": thread_id, "thread_name": "🔇 Old muted index title"},
            {"id": thread_id, "thread_name": "Latest audible index title"},
        )

        info = HELPER.resolve_thread(self.database_path, thread_id)
        decision = HELPER.notification_decision(
            info,
            thread_id,
            self.codex_home / "pending-notifications",
            settle_seconds=0,
        )

        self.assertEqual("Latest audible index title", info.title)
        self.assertEqual("play", decision)


if __name__ == "__main__":
    unittest.main()
