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
  STASH_HISTORY.md
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

Optional frontend config generation during install:

```bash
STASH_FRONTEND_CONFIG_PATH="/absolute/path/to/Backend.xcconfig" ./scripts/install_stack.sh
```

## Smoke test

```bash
./scripts/smoke_test_backend.sh
```

Codex CLI integration test (mocked Codex binary, full planner+executor API path):

```bash
./scripts/integration_test_codex_cli_mock.sh
```

## Key env vars

- `STASH_HOST` (default `127.0.0.1`)
- `STASH_PORT` (default `8765`)
- `STASH_SCAN_INTERVAL_SECONDS` (default `5`)
- `STASH_VECTOR_DIM` (default `256`)
- `STASH_MAX_FILE_SIZE_BYTES` (default `5242880`)
- `STASH_CODEX_MODE` (`shell` or `cli`, default `cli`)
- `STASH_CODEX_BIN` (default `codex`)
- `STASH_PLANNER_CMD` (optional external planner command)
- `STASH_PLANNER_TIMEOUT_SECONDS` (default `150`)
- `STASH_OPENAI_API_KEY` (or `OPENAI_API_KEY`, enables GPT planner)
- `STASH_OPENAI_MODEL` (default `gpt-5-mini`)
- `STASH_OPENAI_BASE_URL` (default `https://api.openai.com/v1`)
- `STASH_OPENAI_TIMEOUT_SECONDS` (default `60`)
- `STASH_LOG_LEVEL` (default `INFO`)

## Notes

- Planning chain is: `STASH_PLANNER_CMD` (if set) -> OpenAI GPT planner (if API key is set) -> Codex CLI planner.
- Ensure local auth is ready: `codex login status` should report logged in.
- Tagged command protocol is still supported directly for explicit runs.
- The vector index uses local hashed embeddings by default, so no cloud dependency is required for search.
- Integration diagnostics endpoint: `GET /health/integrations`
