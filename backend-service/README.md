# Stash Backend Service

Local-first FastAPI backend for the Stash macOS app.

## What this service implements

- Local HTTP service on `127.0.0.1:8765`
- Project folders as the source of truth
- Per-project persistent state in `PROJECT_ROOT/.stash/`
- SQLite metadata and conversation history
- Local vector index for retrieval
- Background file watcher + indexing
- Codex tagged-command execution in controlled worktree folders
- Conversation/run/event APIs for history and resume

## Project portability rule

Every project stores all backend state inside the project folder:

```text
<project_root>/
  .stash/
    project.json
    stash.db
    skills/
      indexing_skill.md
      execution_skill.md
    worktrees/
    logs/
```

This makes projects resumable by simply opening the same folder on another machine/user account (with proper file permissions).

## Permissions and sudo behavior

- The backend never auto-runs `sudo`.
- On project open, it checks read/write permissions and reports whether elevated privileges are required.
- If the folder is read-only, write operations (indexing, command execution) are blocked with a clear error and remediation hint.

## Run

```bash
cd backend-service
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
uvicorn stash_backend.main:app --host 127.0.0.1 --port 8765 --reload
```

## One-command setup from repo root

```bash
./scripts/install_stack.sh
./scripts/run_backend.sh
```

## Smoke test

```bash
./scripts/smoke_test_backend.sh
```

## Key env vars

- `STASH_HOST` (default `127.0.0.1`)
- `STASH_PORT` (default `8765`)
- `STASH_SCAN_INTERVAL_SECONDS` (default `5`)
- `STASH_VECTOR_DIM` (default `256`)
- `STASH_MAX_FILE_SIZE_BYTES` (default `5242880`)
- `STASH_CODEX_MODE` (`shell` or `cli`, default `shell`)
- `STASH_CODEX_BIN` (default `codex`)
- `STASH_PLANNER_CMD` (optional external planner command)

## Notes

- The planner supports tagged command protocol directly and can be upgraded to GPT planning via `STASH_PLANNER_CMD`.
- The vector index uses local hashed embeddings by default, so no cloud dependency is required for search.
