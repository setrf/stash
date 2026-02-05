from __future__ import annotations

import json
import sqlite3
from pathlib import Path

from .db import ProjectRepository, init_schema
from .permissions import inspect_permissions
from .skills import ensure_skill_files
from .types import ProjectContext
from .utils import make_id, utc_now_iso


class ProjectStore:
    def __init__(self) -> None:
        self._projects: dict[str, ProjectContext] = {}
        self._by_root: dict[str, str] = {}

    def list_projects(self) -> list[ProjectContext]:
        return list(self._projects.values())

    def get(self, project_id: str) -> ProjectContext | None:
        return self._projects.get(project_id)

    def get_by_root(self, root_path: Path) -> ProjectContext | None:
        project_id = self._by_root.get(str(root_path.resolve()))
        if not project_id:
            return None
        return self._projects.get(project_id)

    def open_or_create(self, *, name: str, root_path: str) -> ProjectContext:
        root = Path(root_path).expanduser().resolve()

        if not root.exists():
            root.mkdir(parents=True, exist_ok=True)

        existing = self.get_by_root(root)
        if existing is not None:
            return existing

        permission = inspect_permissions(root)
        if permission.needs_sudo:
            raise PermissionError(
                f"Cannot write project state in {root}. "
                "Grant write permissions or run the service with elevated privileges."
            )

        stash_dir = root / ".stash"
        stash_dir.mkdir(parents=True, exist_ok=True)
        (stash_dir / "worktrees").mkdir(parents=True, exist_ok=True)
        (stash_dir / "logs").mkdir(parents=True, exist_ok=True)

        # Make project state self-documenting for portability.
        readme_path = stash_dir / "README.md"
        if not readme_path.exists():
            readme_path.write_text(
                "This folder contains portable Stash state for this project.\n"
                "Copy the project folder and reopen it in Stash to resume history.\n",
                encoding="utf-8",
            )

        project_meta_path = stash_dir / "project.json"
        project_id = ""
        created_at = utc_now_iso()
        saved_name = name

        if project_meta_path.exists():
            try:
                meta = json.loads(project_meta_path.read_text(encoding="utf-8"))
                project_id = str(meta.get("id", ""))
                created_at = str(meta.get("created_at", created_at))
                saved_name = str(meta.get("name", name))
            except json.JSONDecodeError:
                project_id = ""

        if not project_id:
            project_id = make_id("proj")

        meta_payload = {
            "id": project_id,
            "name": saved_name,
            "root_path": str(root),
            "created_at": created_at,
            "last_opened_at": utc_now_iso(),
        }
        project_meta_path.write_text(json.dumps(meta_payload, indent=2), encoding="utf-8")

        ensure_skill_files(stash_dir)

        db_path = stash_dir / "stash.db"
        conn = sqlite3.connect(db_path, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        init_schema(conn)

        context = ProjectContext(
            project_id=project_id,
            name=saved_name,
            root_path=root,
            stash_dir=stash_dir,
            db_path=db_path,
            conn=conn,
            permission=permission,
        )
        repo = ProjectRepository(context)
        repo.ensure_project_meta(project_id=project_id, name=saved_name)

        self._projects[project_id] = context
        self._by_root[str(root)] = project_id
        return context

    def close(self) -> None:
        for context in self._projects.values():
            try:
                context.conn.close()
            except Exception:
                continue
        self._projects.clear()
        self._by_root.clear()
