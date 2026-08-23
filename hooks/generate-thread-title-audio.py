from __future__ import annotations

import argparse
import asyncio
from contextlib import closing
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import time
import uuid

VOICE = "zh-TW-HsiaoYuNeural"
RATE = "-6%"
PITCH = "+22Hz"
VOLUME = "+0%"
SETTINGS_VERSION = "hsiaoyu-rate-6-pitch-22-volume-4db-v1"
TRANSCRIPT_TAIL_BYTES = 2 * 1024 * 1024


@dataclass(frozen=True)
class ThreadInfo:
    title: str | None
    thread_source: str | None
    rollout_path: Path | None
    has_parent: bool


def contains_parent_thread_id(value: object) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "parent_thread_id" and child:
                return True
            if contains_parent_thread_id(child):
                return True
    elif isinstance(value, list):
        return any(contains_parent_thread_id(child) for child in value)
    return False


def _has_spawn_edge(connection: sqlite3.Connection, thread_id: str) -> bool:
    try:
        row = connection.execute(
            """
            SELECT EXISTS (
                SELECT 1 FROM thread_spawn_edges WHERE child_thread_id = ?
            )
            """,
            (thread_id,),
        ).fetchone()
        return bool(row and row[0])
    except sqlite3.OperationalError:
        # Older Codex databases may not have thread_spawn_edges yet. The source
        # JSON and thread_source checks still cover their parent relationships.
        return False


def resolve_session_index_title(database_path: Path, thread_id: str) -> str | None:
    index_path = database_path.parent / "session_index.jsonl"
    if not index_path.is_file():
        return None

    title = None
    try:
        with index_path.open("rb") as index_file:
            for raw_line in index_file:
                try:
                    record = json.loads(raw_line.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    continue

                if not isinstance(record, dict) or record.get("id") != thread_id:
                    continue

                candidate = record.get("thread_name")
                if isinstance(candidate, str) and candidate.strip():
                    title = candidate.strip()
    except OSError:
        return None

    return title


def resolve_thread(database_path: Path, thread_id: str) -> ThreadInfo | None:
    if not database_path.is_file():
        return None

    database_uri = f"{database_path.resolve().as_uri()}?mode=ro"
    with closing(
        sqlite3.connect(database_uri, uri=True, timeout=1.0)
    ) as connection:
        row = connection.execute(
            """
            SELECT name, thread_source, rollout_path, source
            FROM threads
            WHERE id = ?
            """,
            (thread_id,),
        ).fetchone()
        has_spawn_edge = _has_spawn_edge(connection, thread_id)

    if row is None:
        return None

    title = str(row[0]).strip() if row[0] is not None else None
    if not title:
        title = resolve_session_index_title(database_path, thread_id)
    thread_source = str(row[1]).strip() if row[1] is not None else None
    rollout_path_text = str(row[2]).strip() if row[2] is not None else None
    source_text = str(row[3]).strip() if row[3] is not None else None

    source_has_parent = False
    if source_text:
        try:
            source_has_parent = contains_parent_thread_id(json.loads(source_text))
        except (TypeError, ValueError):
            source_has_parent = False

    return ThreadInfo(
        title=title or None,
        thread_source=thread_source or None,
        rollout_path=Path(rollout_path_text) if rollout_path_text else None,
        has_parent=(
            thread_source == "subagent" or has_spawn_edge or source_has_parent
        ),
    )


def latest_lifecycle_state(rollout_path: Path | None) -> str:
    if rollout_path is None or not rollout_path.is_file():
        return "unknown"

    latest_state = "unknown"
    with rollout_path.open("rb") as transcript:
        file_size = transcript.seek(0, os.SEEK_END)
        start_offset = max(0, file_size - TRANSCRIPT_TAIL_BYTES)
        transcript.seek(start_offset)
        if start_offset > 0:
            transcript.readline()

        for raw_line in transcript:
            try:
                record = json.loads(raw_line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue

            if record.get("type") != "event_msg":
                continue

            payload_type = record.get("payload", {}).get("type")
            if payload_type == "task_started":
                latest_state = "active"
            elif payload_type == "task_complete":
                latest_state = "complete"

    return latest_state


def notification_decision(
    info: ThreadInfo | None,
    thread_id: str,
    pending_dir: Path,
    settle_seconds: float,
) -> str:
    if info is not None and info.has_parent:
        return "silence-spawned"

    if info is None:
        return "silence-unknown"

    pending_dir.mkdir(parents=True, exist_ok=True)
    marker_name = hashlib.sha256(thread_id.encode("utf-8")).hexdigest()[:24]
    marker_path = pending_dir / f"{marker_name}.token"
    token = uuid.uuid4().hex
    temporary_path = pending_dir / f".{marker_name}.{token}.tmp"

    try:
        temporary_path.write_text(token, encoding="ascii")
        os.replace(temporary_path, marker_path)
    finally:
        temporary_path.unlink(missing_ok=True)

    time.sleep(max(0.0, min(settle_seconds, 300.0)))

    try:
        if marker_path.read_text(encoding="ascii").strip() != token:
            return "silence-superseded"
    except OSError:
        return "silence-superseded"

    if latest_lifecycle_state(info.rollout_path) == "active":
        return "silence-followup"

    return "play"


async def synthesize_title(title: str, output_path: Path) -> None:
    import edge_tts

    raw_path = output_path.with_suffix(".raw.tmp.mp3")
    processed_path = output_path.with_suffix(".new.tmp.mp3")

    try:
        communicate = edge_tts.Communicate(
            text=f"{title}。",
            voice=VOICE,
            rate=RATE,
            pitch=PITCH,
            volume=VOLUME,
        )
        await communicate.save(str(raw_path))

        ffmpeg_path = shutil.which("ffmpeg")
        if ffmpeg_path:
            subprocess.run(
                [
                    ffmpeg_path,
                    "-y",
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-i",
                    str(raw_path),
                    "-af",
                    "volume=4dB",
                    "-codec:a",
                    "libmp3lame",
                    "-b:a",
                    "96k",
                    str(processed_path),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            os.replace(processed_path, output_path)
        else:
            os.replace(raw_path, output_path)
    finally:
        raw_path.unlink(missing_ok=True)
        processed_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--database", required=True, type=Path)
    parser.add_argument("--cache-dir", type=Path)
    parser.add_argument("--classify-only", action="store_true")
    parser.add_argument("--decision-only", action="store_true")
    parser.add_argument("--pending-dir", type=Path)
    parser.add_argument("--settle-seconds", type=float, default=15.0)
    args = parser.parse_args()

    try:
        info = resolve_thread(args.database, args.thread_id)

        if args.classify_only:
            if info is not None and info.has_parent:
                sys.stdout.write("spawned")
            elif info is not None:
                sys.stdout.write("main")
            else:
                sys.stdout.write("unknown")
            return 0

        if args.decision_only:
            if args.pending_dir is None:
                return 0
            sys.stdout.write(
                notification_decision(
                    info,
                    args.thread_id,
                    args.pending_dir,
                    args.settle_seconds,
                )
            )
            return 0

        if args.cache_dir is None:
            return 0

        if info is None or info.title is None:
            return 0

        cache_key = hashlib.sha256(
            f"{args.thread_id}\0{info.title}\0{SETTINGS_VERSION}".encode("utf-8")
        ).hexdigest()[:24]
        args.cache_dir.mkdir(parents=True, exist_ok=True)
        output_path = args.cache_dir / f"thread-title-{cache_key}.mp3"

        if not output_path.is_file() or output_path.stat().st_size == 0:
            asyncio.run(synthesize_title(info.title, output_path))

        if output_path.is_file() and output_path.stat().st_size > 0:
            sys.stdout.write(str(output_path))
        return 0
    except Exception:
        # The notification wrapper treats an empty result as a safe, silent failure.
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
