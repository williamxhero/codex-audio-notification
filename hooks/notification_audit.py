from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import time
from typing import Any

LOG_FILENAME = "notification-audit.jsonl"
MAX_LOG_BYTES = 1024 * 1024
BACKUP_COUNT = 3
LOCK_WAIT_SECONDS = 2.0
STALE_LOCK_SECONDS = 30.0

AUDIT_FIELDS = frozenset(
    {
        "timestamp",
        "eventType",
        "threadId",
        "turnId",
        "cwd",
        "source",
        "profile",
        "decision",
        "reason",
        "prefixPlayed",
        "titlePlayed",
        "errorStage",
        "errorType",
    }
)


def _clean_text(value: object, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.strip()
    return cleaned[:limit] if cleaned else None


def build_audit_record(
    *,
    event_type: str | None,
    thread_id: str | None,
    turn_id: str | None,
    cwd: str | None,
    source: str,
    profile: str,
    decision: str,
    reason: str,
    prefix_played: bool,
    title_played: bool,
    error_stage: str | None = None,
    error_type: str | None = None,
    timestamp: str | None = None,
) -> dict[str, Any]:
    return {
        "timestamp": timestamp
        or datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"
        ),
        "eventType": _clean_text(event_type, 128),
        "threadId": _clean_text(thread_id, 256),
        "turnId": _clean_text(turn_id, 256),
        "cwd": _clean_text(cwd, 1024),
        "source": _clean_text(source, 32) or "unknown",
        "profile": _clean_text(profile, 64) or "unknown",
        "decision": _clean_text(decision, 128) or "silence-error",
        "reason": _clean_text(reason, 256) or "unspecified",
        "prefixPlayed": bool(prefix_played),
        "titlePlayed": bool(title_played),
        "errorStage": _clean_text(error_stage, 128),
        "errorType": _clean_text(error_type, 128),
    }


def _acquire_lock(lock_path: Path) -> int | None:
    deadline = time.monotonic() + LOCK_WAIT_SECONDS
    while True:
        try:
            descriptor = os.open(
                lock_path,
                os.O_CREAT | os.O_EXCL | os.O_WRONLY,
                0o600,
            )
            os.write(descriptor, str(os.getpid()).encode("ascii"))
            return descriptor
        except (FileExistsError, PermissionError):
            try:
                if time.time() - lock_path.stat().st_mtime > STALE_LOCK_SECONDS:
                    lock_path.unlink(missing_ok=True)
                    continue
            except OSError:
                pass

            if time.monotonic() >= deadline:
                return None
            time.sleep(0.01)
        except OSError:
            return None


def _release_lock(lock_path: Path, descriptor: int) -> None:
    try:
        os.close(descriptor)
    finally:
        lock_path.unlink(missing_ok=True)


def _rotate_if_needed(
    log_path: Path,
    incoming_bytes: int,
    max_bytes: int,
    backup_count: int,
) -> None:
    try:
        current_bytes = log_path.stat().st_size
    except FileNotFoundError:
        return

    if current_bytes + incoming_bytes <= max_bytes:
        return

    if backup_count <= 0:
        log_path.unlink(missing_ok=True)
        return

    oldest = log_path.with_name(f"{log_path.name}.{backup_count}")
    oldest.unlink(missing_ok=True)
    for index in range(backup_count - 1, 0, -1):
        source = log_path.with_name(f"{log_path.name}.{index}")
        destination = log_path.with_name(f"{log_path.name}.{index + 1}")
        if source.exists():
            os.replace(source, destination)
    os.replace(log_path, log_path.with_name(f"{log_path.name}.1"))


def write_audit_record(
    log_directory: Path,
    record: dict[str, Any],
    *,
    max_bytes: int = MAX_LOG_BYTES,
    backup_count: int = BACKUP_COUNT,
) -> bool:
    safe_record = {field: record.get(field) for field in AUDIT_FIELDS}
    encoded_line = (
        json.dumps(safe_record, ensure_ascii=False, separators=(",", ":")) + "\n"
    ).encode("utf-8")

    log_directory.mkdir(parents=True, exist_ok=True)
    log_path = log_directory / LOG_FILENAME
    lock_path = log_directory / f"{LOG_FILENAME}.lock"
    descriptor = _acquire_lock(lock_path)
    if descriptor is None:
        return False

    try:
        _rotate_if_needed(log_path, len(encoded_line), max_bytes, backup_count)
        flags = os.O_CREAT | os.O_WRONLY | os.O_APPEND
        if hasattr(os, "O_BINARY"):
            flags |= os.O_BINARY
        log_descriptor = os.open(log_path, flags, 0o600)
        try:
            os.write(log_descriptor, encoded_line)
        finally:
            os.close(log_descriptor)
        return True
    finally:
        _release_lock(lock_path, descriptor)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-directory", required=True, type=Path)
    parser.add_argument("--event-type")
    parser.add_argument("--thread-id")
    parser.add_argument("--turn-id")
    parser.add_argument("--cwd")
    parser.add_argument("--source", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--decision", required=True)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--prefix-played", action="store_true")
    parser.add_argument("--title-played", action="store_true")
    parser.add_argument("--error-stage")
    parser.add_argument("--error-type")
    args = parser.parse_args()

    try:
        record = build_audit_record(
            event_type=args.event_type,
            thread_id=args.thread_id,
            turn_id=args.turn_id,
            cwd=args.cwd,
            source=args.source,
            profile=args.profile,
            decision=args.decision,
            reason=args.reason,
            prefix_played=args.prefix_played,
            title_played=args.title_played,
            error_stage=args.error_stage,
            error_type=args.error_type,
        )
        write_audit_record(args.log_directory, record)
    except Exception:
        # Auditing must never affect notification decisions or Codex itself.
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
