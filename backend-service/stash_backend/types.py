from __future__ import annotations

import sqlite3
import threading
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass(slots=True)
class PermissionReport:
    path: str
    exists: bool
    readable: bool
    writable: bool
    executable: bool
    stash_writable: bool
    needs_sudo: bool
    mode_octal: str
    owner_uid: int | None
    owner_gid: int | None
    detail: str | None = None


@dataclass(slots=True)
class ProjectContext:
    project_id: str
    name: str
    root_path: Path
    stash_dir: Path
    db_path: Path
    conn: sqlite3.Connection
    lock: threading.RLock = field(default_factory=threading.RLock)
    permission: PermissionReport | None = None


@dataclass(slots=True)
class TaggedCommand:
    raw: str
    cmd: str
    worktree: str | None = None
    cwd: str | None = None


@dataclass(slots=True)
class PlanResult:
    planner_text: str
    commands: list[TaggedCommand]
    timed_out_primary: bool = False
    used_backend: str = "unknown"
    used_fallback: str | None = None


@dataclass(slots=True)
class ExecutionResult:
    engine: str
    exit_code: int
    stdout: str
    stderr: str
    started_at: str
    finished_at: str
    cwd: str
    worktree_path: str


@dataclass(slots=True)
class DirectCommandResult:
    command: str
    exit_code: int
    output: str
    status: str
    cwd: str | None = None
    started_at: str | None = None
    finished_at: str | None = None


@dataclass(slots=True)
class DirectExecutionResult:
    engine: str
    assistant_text: str
    commands: list[DirectCommandResult]
    started_at: str
    finished_at: str
    cwd: str
    worktree_path: str


@dataclass(slots=True)
class IndexJob:
    job_id: str
    project_id: str
    status: str
    started_at: str
    finished_at: str | None = None
    detail: dict[str, Any] = field(default_factory=dict)
