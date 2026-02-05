from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any

from .types import ProjectContext
from .utils import dumps_json, loads_json, make_id, utc_now_iso


SCHEMA_SQL = """
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS project_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  status TEXT NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0,
  summary TEXT,
  created_at TEXT NOT NULL,
  last_message_at TEXT
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  parts_json TEXT,
  parent_message_id TEXT,
  sequence_no INTEGER NOT NULL,
  superseded_by TEXT,
  metadata_json TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY(conversation_id) REFERENCES conversations(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_conv_seq ON messages(conversation_id, sequence_no);
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages(created_at);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL,
  trigger_message_id TEXT NOT NULL,
  status TEXT NOT NULL,
  mode TEXT NOT NULL,
  output_summary TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  finished_at TEXT,
  FOREIGN KEY(conversation_id) REFERENCES conversations(id),
  FOREIGN KEY(trigger_message_id) REFERENCES messages(id)
);

CREATE TABLE IF NOT EXISTS run_steps (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL,
  step_index INTEGER NOT NULL,
  step_type TEXT NOT NULL,
  status TEXT NOT NULL,
  input_json TEXT,
  output_json TEXT,
  error TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  FOREIGN KEY(run_id) REFERENCES runs(id)
);

CREATE TABLE IF NOT EXISTS assets (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT,
  path_or_url TEXT,
  content TEXT,
  tags_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  indexed_at TEXT,
  last_error TEXT
);

CREATE INDEX IF NOT EXISTS idx_assets_kind_path ON assets(kind, path_or_url);

CREATE TABLE IF NOT EXISTS message_attachments (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  snippet_ref TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY(message_id) REFERENCES messages(id),
  FOREIGN KEY(asset_id) REFERENCES assets(id)
);

CREATE TABLE IF NOT EXISTS chunks (
  id TEXT PRIMARY KEY,
  asset_id TEXT NOT NULL,
  source_type TEXT NOT NULL,
  source_ref TEXT,
  text TEXT NOT NULL,
  token_count INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(asset_id) REFERENCES assets(id)
);

CREATE TABLE IF NOT EXISTS embeddings (
  id TEXT PRIMARY KEY,
  chunk_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  vector_json TEXT NOT NULL,
  dim INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY(chunk_id) REFERENCES chunks(id),
  FOREIGN KEY(asset_id) REFERENCES assets(id)
);

CREATE INDEX IF NOT EXISTS idx_embeddings_asset ON embeddings(asset_id);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  conversation_id TEXT,
  run_id TEXT,
  ts TEXT NOT NULL,
  payload_json TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);

CREATE TABLE IF NOT EXISTS file_snapshots (
  path TEXT PRIMARY KEY,
  modified_time REAL NOT NULL,
  size_bytes INTEGER NOT NULL,
  hash TEXT,
  last_indexed_at TEXT NOT NULL
);
"""


PROJECT_META_DEFAULTS = {
    "name": "Unnamed Project",
    "created_at": "",
    "last_opened_at": "",
    "active_conversation_id": "",
}

PROJECT_HISTORY_FILENAME = "STASH_HISTORY.md"
MAX_HISTORY_PAYLOAD_CHARS = 1200


def init_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(SCHEMA_SQL)
    conn.commit()


def _row_to_dict(row: sqlite3.Row | None) -> dict[str, Any] | None:
    if row is None:
        return None
    return {k: row[k] for k in row.keys()}


class ProjectRepository:
    def __init__(self, context: ProjectContext):
        self.ctx = context

    def _execute(self, sql: str, params: tuple[Any, ...] = ()) -> sqlite3.Cursor:
        with self.ctx.lock:
            cur = self.ctx.conn.execute(sql, params)
            self.ctx.conn.commit()
            return cur

    def _fetchone(self, sql: str, params: tuple[Any, ...] = ()) -> dict[str, Any] | None:
        with self.ctx.lock:
            row = self.ctx.conn.execute(sql, params).fetchone()
        return _row_to_dict(row)

    def _fetchall(self, sql: str, params: tuple[Any, ...] = ()) -> list[dict[str, Any]]:
        with self.ctx.lock:
            rows = self.ctx.conn.execute(sql, params).fetchall()
        return [_row_to_dict(r) for r in rows if r is not None]

    def _project_history_path(self) -> Path:
        return self.ctx.root_path / PROJECT_HISTORY_FILENAME

    def _ensure_history_header(self, path: Path) -> None:
        if path.exists():
            return
        path.write_text(
            (
                "# Stash Project History\n\n"
                "This file is auto-generated by Stash backend.\n"
                "It records project events so new users can resume context from the folder itself.\n\n"
            ),
            encoding="utf-8",
        )

    def _append_history_event(self, event: dict[str, Any]) -> None:
        path = self._project_history_path()
        self._ensure_history_header(path)

        details: list[str] = [f"type={event['type']}"]
        if event.get("conversation_id"):
            details.append(f"conversation={event['conversation_id']}")
        if event.get("run_id"):
            details.append(f"run={event['run_id']}")

        payload = event.get("payload") or {}
        if payload:
            payload_text = dumps_json(payload).replace("\n", " ")
            if len(payload_text) > MAX_HISTORY_PAYLOAD_CHARS:
                payload_text = payload_text[:MAX_HISTORY_PAYLOAD_CHARS] + "... (truncated)"
            details.append(f"payload={payload_text}")

        line = f"- `{event['ts']}` {' | '.join(details)}\n"
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)

    def set_meta(self, key: str, value: str) -> None:
        self._execute(
            """
            INSERT INTO project_meta(key, value) VALUES(?, ?)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """,
            (key, value),
        )

    def get_meta(self, key: str, default: str | None = None) -> str | None:
        row = self._fetchone("SELECT value FROM project_meta WHERE key=?", (key,))
        if not row:
            return default
        return row["value"]

    def ensure_project_meta(self, *, project_id: str, name: str) -> None:
        now = utc_now_iso()
        for key, value in PROJECT_META_DEFAULTS.items():
            existing = self.get_meta(key)
            if existing is None:
                self.set_meta(key, value)
        if not self.get_meta("project_id"):
            self.set_meta("project_id", project_id)
        if not self.get_meta("created_at"):
            self.set_meta("created_at", now)
        self.set_meta("name", name)
        self.set_meta("last_opened_at", now)

    def project_view(self) -> dict[str, Any]:
        return {
            "id": self.get_meta("project_id", self.ctx.project_id),
            "name": self.get_meta("name", self.ctx.name),
            "root_path": str(self.ctx.root_path),
            "created_at": self.get_meta("created_at"),
            "last_opened_at": self.get_meta("last_opened_at"),
            "active_conversation_id": self.get_meta("active_conversation_id") or None,
        }

    def update_project(self, *, name: str | None = None, active_conversation_id: str | None = None) -> dict[str, Any]:
        if name is not None:
            self.set_meta("name", name)
            self.ctx.name = name
        if active_conversation_id is not None:
            self.set_meta("active_conversation_id", active_conversation_id)
        self.set_meta("last_opened_at", utc_now_iso())
        return self.project_view()

    def create_conversation(self, title: str, *, status: str = "active", pinned: bool = False) -> dict[str, Any]:
        conv_id = make_id("conv")
        now = utc_now_iso()
        self._execute(
            """
            INSERT INTO conversations(id, title, status, pinned, summary, created_at, last_message_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            (conv_id, title, status, 1 if pinned else 0, None, now, None),
        )
        self.set_meta("active_conversation_id", conv_id)
        return self.get_conversation(conv_id)

    def list_conversations(
        self,
        *,
        status: str | None = None,
        pinned: bool | None = None,
        q: str | None = None,
        limit: int = 50,
        cursor: str | None = None,
    ) -> list[dict[str, Any]]:
        clauses: list[str] = []
        params: list[Any] = []
        if status:
            clauses.append("status = ?")
            params.append(status)
        if pinned is not None:
            clauses.append("pinned = ?")
            params.append(1 if pinned else 0)
        if q:
            clauses.append("LOWER(title) LIKE ?")
            params.append(f"%{q.lower()}%")
        if cursor:
            clauses.append("COALESCE(last_message_at, created_at) < ?")
            params.append(cursor)

        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        rows = self._fetchall(
            f"""
            SELECT id, title, status, pinned, summary, created_at, last_message_at
            FROM conversations
            {where}
            ORDER BY COALESCE(last_message_at, created_at) DESC, created_at DESC
            LIMIT ?
            """,
            tuple([*params, limit]),
        )
        return [self._conversation_row_to_view(r) for r in rows]

    def _conversation_row_to_view(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": row["id"],
            "project_id": self.ctx.project_id,
            "title": row["title"],
            "status": row["status"],
            "pinned": bool(row["pinned"]),
            "summary": row.get("summary"),
            "created_at": row["created_at"],
            "last_message_at": row.get("last_message_at"),
        }

    def get_conversation(self, conversation_id: str) -> dict[str, Any] | None:
        row = self._fetchone(
            "SELECT id, title, status, pinned, summary, created_at, last_message_at FROM conversations WHERE id=?",
            (conversation_id,),
        )
        if not row:
            return None
        return self._conversation_row_to_view(row)

    def update_conversation(self, conversation_id: str, *, title: str | None, status: str | None, pinned: bool | None, summary: str | None) -> dict[str, Any] | None:
        conv = self.get_conversation(conversation_id)
        if not conv:
            return None
        next_title = title if title is not None else conv["title"]
        next_status = status if status is not None else conv["status"]
        next_pinned = 1 if (pinned if pinned is not None else conv["pinned"]) else 0
        next_summary = summary if summary is not None else conv.get("summary")
        self._execute(
            """
            UPDATE conversations
            SET title=?, status=?, pinned=?, summary=?
            WHERE id=?
            """,
            (next_title, next_status, next_pinned, next_summary, conversation_id),
        )
        return self.get_conversation(conversation_id)

    def fork_conversation(self, conversation_id: str, *, from_message_id: str | None, title: str | None) -> dict[str, Any] | None:
        source = self.get_conversation(conversation_id)
        if not source:
            return None
        max_seq = None
        if from_message_id:
            msg = self.get_message(conversation_id, from_message_id)
            if not msg:
                return None
            max_seq = msg["sequence_no"]

        new_conv = self.create_conversation(title or f"{source['title']} (fork)")

        params: list[Any] = [conversation_id]
        extra = ""
        if max_seq is not None:
            extra = " AND sequence_no <= ?"
            params.append(max_seq)

        source_messages = self._fetchall(
            f"""
            SELECT role, content, parts_json, parent_message_id, sequence_no, metadata_json, created_at
            FROM messages
            WHERE conversation_id = ? {extra}
            ORDER BY sequence_no ASC
            """,
            tuple(params),
        )

        seq_no = 0
        for message in source_messages:
            seq_no += 1
            msg_id = make_id("msg")
            self._execute(
                """
                INSERT INTO messages(id, conversation_id, role, content, parts_json, parent_message_id, sequence_no, superseded_by, metadata_json, created_at)
                VALUES(?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                (
                    msg_id,
                    new_conv["id"],
                    message["role"],
                    message["content"],
                    message.get("parts_json"),
                    message.get("parent_message_id"),
                    seq_no,
                    message.get("metadata_json"),
                    message["created_at"],
                ),
            )

        self._execute(
            "UPDATE conversations SET last_message_at=(SELECT MAX(created_at) FROM messages WHERE conversation_id=?) WHERE id=?",
            (new_conv["id"], new_conv["id"]),
        )
        return self.get_conversation(new_conv["id"])

    def next_sequence_no(self, conversation_id: str) -> int:
        row = self._fetchone(
            "SELECT COALESCE(MAX(sequence_no), 0) AS seq FROM messages WHERE conversation_id=?",
            (conversation_id,),
        )
        return int(row["seq"]) + 1 if row else 1

    def create_message(
        self,
        conversation_id: str,
        *,
        role: str,
        content: str,
        parts: list[dict[str, Any]] | None,
        parent_message_id: str | None,
        metadata: dict[str, Any] | None = None,
        created_at: str | None = None,
    ) -> dict[str, Any]:
        msg_id = make_id("msg")
        now = created_at or utc_now_iso()
        sequence = self.next_sequence_no(conversation_id)

        self._execute(
            """
            INSERT INTO messages(
              id, conversation_id, role, content, parts_json,
              parent_message_id, sequence_no, superseded_by, metadata_json, created_at
            )
            VALUES(?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            """,
            (
                msg_id,
                conversation_id,
                role,
                content,
                dumps_json(parts or []),
                parent_message_id,
                sequence,
                dumps_json(metadata or {}),
                now,
            ),
        )

        self._execute("UPDATE conversations SET last_message_at=? WHERE id=?", (now, conversation_id))
        return self.get_message(conversation_id, msg_id)  # type: ignore[return-value]

    def get_message(self, conversation_id: str, message_id: str) -> dict[str, Any] | None:
        row = self._fetchone(
            """
            SELECT id, conversation_id, role, content, parts_json, parent_message_id,
                   sequence_no, superseded_by, metadata_json, created_at
            FROM messages
            WHERE conversation_id=? AND id=?
            """,
            (conversation_id, message_id),
        )
        if not row:
            return None
        return self._message_row_to_view(row)

    def list_messages(self, conversation_id: str, *, cursor: int | None, limit: int = 200) -> list[dict[str, Any]]:
        if cursor is None:
            rows = self._fetchall(
                """
                SELECT id, conversation_id, role, content, parts_json, parent_message_id,
                       sequence_no, superseded_by, metadata_json, created_at
                FROM messages
                WHERE conversation_id=?
                ORDER BY sequence_no ASC
                LIMIT ?
                """,
                (conversation_id, limit),
            )
        else:
            rows = self._fetchall(
                """
                SELECT id, conversation_id, role, content, parts_json, parent_message_id,
                       sequence_no, superseded_by, metadata_json, created_at
                FROM messages
                WHERE conversation_id=? AND sequence_no > ?
                ORDER BY sequence_no ASC
                LIMIT ?
                """,
                (conversation_id, cursor, limit),
            )
        return [self._message_row_to_view(r) for r in rows]

    def _message_row_to_view(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": row["id"],
            "project_id": self.ctx.project_id,
            "conversation_id": row["conversation_id"],
            "role": row["role"],
            "content": row["content"],
            "parts": loads_json(row.get("parts_json"), []),
            "parent_message_id": row.get("parent_message_id"),
            "sequence_no": int(row["sequence_no"]),
            "superseded_by": row.get("superseded_by"),
            "metadata": loads_json(row.get("metadata_json"), {}),
            "created_at": row["created_at"],
        }

    def mark_message_superseded(self, conversation_id: str, message_id: str) -> dict[str, Any] | None:
        new_id = make_id("msg")
        self._execute(
            "UPDATE messages SET superseded_by=? WHERE id=? AND conversation_id=?",
            (new_id, message_id, conversation_id),
        )
        return self.get_message(conversation_id, message_id)

    def create_run(self, conversation_id: str, trigger_message_id: str, *, mode: str) -> dict[str, Any]:
        run_id = make_id("run")
        now = utc_now_iso()
        self._execute(
            """
            INSERT INTO runs(id, conversation_id, trigger_message_id, status, mode, output_summary, error, created_at, finished_at)
            VALUES(?, ?, ?, 'pending', ?, NULL, NULL, ?, NULL)
            """,
            (run_id, conversation_id, trigger_message_id, mode, now),
        )
        return self.get_run(run_id)  # type: ignore[return-value]

    def get_run(self, run_id: str) -> dict[str, Any] | None:
        row = self._fetchone(
            """
            SELECT id, conversation_id, trigger_message_id, status, mode, output_summary, error, created_at, finished_at
            FROM runs WHERE id=?
            """,
            (run_id,),
        )
        if not row:
            return None
        return self._run_row_to_view(row)

    def _run_row_to_view(self, row: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": row["id"],
            "project_id": self.ctx.project_id,
            "conversation_id": row["conversation_id"],
            "trigger_message_id": row["trigger_message_id"],
            "status": row["status"],
            "mode": row["mode"],
            "output_summary": row.get("output_summary"),
            "error": row.get("error"),
            "created_at": row["created_at"],
            "finished_at": row.get("finished_at"),
        }

    def update_run(self, run_id: str, *, status: str, output_summary: str | None = None, error: str | None = None, finished: bool = False) -> dict[str, Any] | None:
        finished_at = utc_now_iso() if finished else None
        current = self.get_run(run_id)
        if not current:
            return None
        next_output = output_summary if output_summary is not None else current.get("output_summary")
        next_error = error if error is not None else current.get("error")
        self._execute(
            """
            UPDATE runs
            SET status=?, output_summary=?, error=?, finished_at=COALESCE(?, finished_at)
            WHERE id=?
            """,
            (status, next_output, next_error, finished_at, run_id),
        )
        return self.get_run(run_id)

    def recover_orphaned_runs(
        self,
        *,
        active_run_ids: set[str] | None = None,
        reason: str = "Run interrupted before completion",
    ) -> int:
        active_ids = active_run_ids or set()
        rows = self._fetchall(
            """
            SELECT id, conversation_id
            FROM runs
            WHERE status IN ('pending', 'running') AND finished_at IS NULL
            ORDER BY created_at ASC
            """
        )
        if not rows:
            return 0

        now = utc_now_iso()
        recovered = 0
        for row in rows:
            run_id = str(row["id"])
            if run_id in active_ids:
                continue

            self._execute(
                """
                UPDATE run_steps
                SET status='failed', error=COALESCE(error, ?), finished_at=COALESCE(finished_at, ?)
                WHERE run_id=? AND status='running'
                """,
                (reason, now, run_id),
            )

            self._execute(
                """
                UPDATE runs
                SET status='failed',
                    output_summary=COALESCE(output_summary, 'Run interrupted'),
                    error=COALESCE(error, ?),
                    finished_at=COALESCE(finished_at, ?)
                WHERE id=?
                """,
                (reason, now, run_id),
            )

            self.add_event(
                "run_recovered",
                conversation_id=row.get("conversation_id"),
                run_id=run_id,
                payload={"reason": reason},
            )
            recovered += 1

        return recovered

    def create_run_step(self, run_id: str, step_index: int, step_type: str, input_data: dict[str, Any]) -> str:
        step_id = make_id("step")
        now = utc_now_iso()
        self._execute(
            """
            INSERT INTO run_steps(id, run_id, step_index, step_type, status, input_json, output_json, error, started_at, finished_at)
            VALUES(?, ?, ?, ?, 'running', ?, NULL, NULL, ?, NULL)
            """,
            (step_id, run_id, step_index, step_type, dumps_json(input_data), now),
        )
        return step_id

    def finish_run_step(self, step_id: str, *, status: str, output_data: dict[str, Any] | None = None, error: str | None = None) -> None:
        self._execute(
            """
            UPDATE run_steps
            SET status=?, output_json=?, error=?, finished_at=?
            WHERE id=?
            """,
            (status, dumps_json(output_data or {}), error, utc_now_iso(), step_id),
        )

    def list_run_steps(
        self,
        run_id: str,
        *,
        include_output: bool = True,
        output_char_limit: int | None = None,
    ) -> list[dict[str, Any]]:
        rows = self._fetchall(
            """
            SELECT id, run_id, step_index, step_type, status, input_json, output_json, error, started_at, finished_at
            FROM run_steps
            WHERE run_id=?
            ORDER BY step_index ASC
            """,
            (run_id,),
        )
        result: list[dict[str, Any]] = []
        for r in rows:
            output: dict[str, Any] = {}
            if include_output:
                loaded = loads_json(r.get("output_json"), {})
                if isinstance(loaded, dict):
                    output = loaded
                if output_char_limit and output:
                    trimmed: dict[str, Any] = {}
                    for key, value in output.items():
                        if isinstance(value, str) and len(value) > output_char_limit:
                            trimmed[key] = value[:output_char_limit] + "... (truncated)"
                        else:
                            trimmed[key] = value
                    output = trimmed

            result.append(
                {
                    "id": r["id"],
                    "run_id": r["run_id"],
                    "step_index": r["step_index"],
                    "step_type": r["step_type"],
                    "status": r["status"],
                    "input": loads_json(r.get("input_json"), {}),
                    "output": output,
                    "error": r.get("error"),
                    "started_at": r["started_at"],
                    "finished_at": r.get("finished_at"),
                }
            )
        return result

    def add_event(self, event_type: str, *, conversation_id: str | None = None, run_id: str | None = None, payload: dict[str, Any] | None = None) -> dict[str, Any]:
        now = utc_now_iso()
        cur = self._execute(
            """
            INSERT INTO events(type, conversation_id, run_id, ts, payload_json)
            VALUES(?, ?, ?, ?, ?)
            """,
            (event_type, conversation_id, run_id, now, dumps_json(payload or {})),
        )
        event_id = int(cur.lastrowid)
        event = {
            "id": event_id,
            "type": event_type,
            "project_id": self.ctx.project_id,
            "conversation_id": conversation_id,
            "run_id": run_id,
            "ts": now,
            "payload": payload or {},
        }
        try:
            self._append_history_event(event)
        except OSError:
            # Event insertion remains primary; markdown history is best-effort.
            pass
        return event

    def list_events(self, *, after_id: int = 0, conversation_id: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        if conversation_id:
            rows = self._fetchall(
                """
                SELECT id, type, conversation_id, run_id, ts, payload_json
                FROM events
                WHERE id > ? AND (conversation_id = ? OR conversation_id IS NULL)
                ORDER BY id ASC
                LIMIT ?
                """,
                (after_id, conversation_id, limit),
            )
        else:
            rows = self._fetchall(
                """
                SELECT id, type, conversation_id, run_id, ts, payload_json
                FROM events
                WHERE id > ?
                ORDER BY id ASC
                LIMIT ?
                """,
                (after_id, limit),
            )

        return [
            {
                "id": int(row["id"]),
                "type": row["type"],
                "project_id": self.ctx.project_id,
                "conversation_id": row.get("conversation_id"),
                "run_id": row.get("run_id"),
                "ts": row["ts"],
                "payload": loads_json(row.get("payload_json"), {}),
            }
            for row in rows
        ]

    def create_or_update_asset(
        self,
        *,
        kind: str,
        title: str | None,
        path_or_url: str | None,
        content: str | None,
        tags: list[str],
    ) -> dict[str, Any]:
        now = utc_now_iso()

        existing = None
        if kind == "file" and path_or_url:
            existing = self._fetchone("SELECT id FROM assets WHERE kind='file' AND path_or_url=?", (path_or_url,))

        if existing:
            asset_id = existing["id"]
            self._execute(
                """
                UPDATE assets
                SET title=?, content=?, tags_json=?, updated_at=?, last_error=NULL
                WHERE id=?
                """,
                (title, content, dumps_json(tags), now, asset_id),
            )
        else:
            asset_id = make_id("asset")
            self._execute(
                """
                INSERT INTO assets(id, kind, title, path_or_url, content, tags_json, created_at, updated_at, indexed_at, last_error)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)
                """,
                (asset_id, kind, title, path_or_url, content, dumps_json(tags), now, now),
            )
        return self.get_asset(asset_id)  # type: ignore[return-value]

    def get_asset(self, asset_id: str) -> dict[str, Any] | None:
        row = self._fetchone(
            """
            SELECT id, kind, title, path_or_url, content, tags_json, created_at, updated_at, indexed_at
            FROM assets WHERE id=?
            """,
            (asset_id,),
        )
        if not row:
            return None
        return {
            "id": row["id"],
            "project_id": self.ctx.project_id,
            "kind": row["kind"],
            "title": row.get("title"),
            "path_or_url": row.get("path_or_url"),
            "content": row.get("content"),
            "tags": loads_json(row.get("tags_json"), []),
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
            "indexed_at": row.get("indexed_at"),
        }

    def list_assets(self) -> list[dict[str, Any]]:
        rows = self._fetchall(
            """
            SELECT id, kind, title, path_or_url, content, tags_json, created_at, updated_at, indexed_at
            FROM assets
            ORDER BY updated_at DESC
            """
        )
        return [
            {
                "id": row["id"],
                "project_id": self.ctx.project_id,
                "kind": row["kind"],
                "title": row.get("title"),
                "path_or_url": row.get("path_or_url"),
                "content": row.get("content"),
                "tags": loads_json(row.get("tags_json"), []),
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
                "indexed_at": row.get("indexed_at"),
            }
            for row in rows
        ]

    def set_asset_indexed(self, asset_id: str) -> None:
        self._execute("UPDATE assets SET indexed_at=?, updated_at=?, last_error=NULL WHERE id=?", (utc_now_iso(), utc_now_iso(), asset_id))

    def set_asset_error(self, asset_id: str, error: str) -> None:
        self._execute("UPDATE assets SET last_error=?, updated_at=? WHERE id=?", (error[:2000], utc_now_iso(), asset_id))

    def clear_asset_index(self, asset_id: str) -> None:
        self._execute("DELETE FROM embeddings WHERE asset_id=?", (asset_id,))
        self._execute("DELETE FROM chunks WHERE asset_id=?", (asset_id,))

    def insert_chunk_with_embedding(
        self,
        *,
        asset_id: str,
        source_type: str,
        source_ref: str | None,
        text: str,
        token_count: int,
        vector: list[float],
    ) -> tuple[str, str]:
        chunk_id = make_id("chunk")
        embed_id = make_id("emb")
        now = utc_now_iso()
        self._execute(
            """
            INSERT INTO chunks(id, asset_id, source_type, source_ref, text, token_count, created_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            """,
            (chunk_id, asset_id, source_type, source_ref, text, token_count, now),
        )
        self._execute(
            """
            INSERT INTO embeddings(id, chunk_id, asset_id, vector_json, dim, created_at)
            VALUES(?, ?, ?, ?, ?, ?)
            """,
            (embed_id, chunk_id, asset_id, dumps_json(vector), len(vector), now),
        )
        return chunk_id, embed_id

    def list_embeddings(self) -> list[dict[str, Any]]:
        rows = self._fetchall(
            """
            SELECT e.id AS embedding_id, e.chunk_id, e.asset_id, e.vector_json,
                   c.text, c.source_type, c.source_ref,
                   a.title, a.path_or_url
            FROM embeddings e
            JOIN chunks c ON c.id = e.chunk_id
            JOIN assets a ON a.id = e.asset_id
            """
        )
        return [
            {
                "embedding_id": row["embedding_id"],
                "chunk_id": row["chunk_id"],
                "asset_id": row["asset_id"],
                "vector": loads_json(row.get("vector_json"), []),
                "text": row["text"],
                "source_type": row.get("source_type"),
                "source_ref": row.get("source_ref"),
                "title": row.get("title"),
                "path_or_url": row.get("path_or_url"),
            }
            for row in rows
        ]

    def create_message_attachment(self, message_id: str, asset_id: str, snippet_ref: str | None = None) -> dict[str, Any]:
        attach_id = make_id("attach")
        now = utc_now_iso()
        self._execute(
            """
            INSERT INTO message_attachments(id, message_id, asset_id, snippet_ref, created_at)
            VALUES(?, ?, ?, ?, ?)
            """,
            (attach_id, message_id, asset_id, snippet_ref, now),
        )
        return {
            "id": attach_id,
            "message_id": message_id,
            "asset_id": asset_id,
            "snippet_ref": snippet_ref,
            "created_at": now,
        }

    def upsert_file_snapshot(self, *, rel_path: str, modified_time: float, size_bytes: int, hash_value: str | None = None) -> None:
        self._execute(
            """
            INSERT INTO file_snapshots(path, modified_time, size_bytes, hash, last_indexed_at)
            VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
              modified_time=excluded.modified_time,
              size_bytes=excluded.size_bytes,
              hash=excluded.hash,
              last_indexed_at=excluded.last_indexed_at
            """,
            (rel_path, modified_time, size_bytes, hash_value, utc_now_iso()),
        )

    def get_file_snapshot(self, rel_path: str) -> dict[str, Any] | None:
        return self._fetchone(
            "SELECT path, modified_time, size_bytes, hash, last_indexed_at FROM file_snapshots WHERE path=?",
            (rel_path,),
        )

    def list_file_snapshots(self) -> list[dict[str, Any]]:
        return self._fetchall("SELECT path, modified_time, size_bytes, hash, last_indexed_at FROM file_snapshots")

    def delete_file_snapshot(self, rel_path: str) -> None:
        self._execute("DELETE FROM file_snapshots WHERE path=?", (rel_path,))

    def timeline(self, *, limit: int = 200) -> list[dict[str, Any]]:
        events = self._fetchall(
            """
            SELECT id, type, conversation_id, run_id, ts, payload_json
            FROM events
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        )
        return [
            {
                "id": row["id"],
                "type": row["type"],
                "project_id": self.ctx.project_id,
                "conversation_id": row.get("conversation_id"),
                "run_id": row.get("run_id"),
                "ts": row["ts"],
                "payload": loads_json(row.get("payload_json"), {}),
            }
            for row in events
        ]

    def history_search(self, *, query: str, limit: int = 20, include_archived: bool = True) -> list[dict[str, Any]]:
        like = f"%{query.lower()}%"
        status_clause = "" if include_archived else "AND c.status='active'"

        rows = self._fetchall(
            f"""
            SELECT 'message' AS item_type, m.id AS id, m.conversation_id AS conversation_id,
                   m.created_at AS ts, m.content AS content
            FROM messages m
            JOIN conversations c ON c.id = m.conversation_id
            WHERE LOWER(m.content) LIKE ? {status_clause}
            UNION ALL
            SELECT 'asset' AS item_type, a.id AS id, NULL AS conversation_id,
                   a.updated_at AS ts, COALESCE(a.title, a.path_or_url, a.content, '') AS content
            FROM assets a
            WHERE LOWER(COALESCE(a.title, '') || ' ' || COALESCE(a.path_or_url, '') || ' ' || COALESCE(a.content, '')) LIKE ?
            ORDER BY ts DESC
            LIMIT ?
            """,
            (like, like, limit),
        )

        return [
            {
                "item_type": row["item_type"],
                "id": row["id"],
                "project_id": self.ctx.project_id,
                "conversation_id": row.get("conversation_id"),
                "ts": row["ts"],
                "content": row["content"],
            }
            for row in rows
        ]

    def transcript(self, conversation_id: str) -> list[dict[str, Any]]:
        return self.list_messages(conversation_id, cursor=None, limit=100000)
