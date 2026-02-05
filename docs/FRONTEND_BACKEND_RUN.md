# Frontend + Backend Local Run Guide

This guide is for frontend developers integrating with the local Stash backend service.

## 1) One-time setup

From repo root:

```bash
./scripts/install_stack.sh
```

This creates `.venv/`, installs backend dependencies, and provisions runtime tools (including `uv`) plus local document packages (including `pypdf`) in that environment.

If you set `STASH_FRONTEND_CONFIG_PATH`, install also writes frontend backend URL config:

```text
STASH_BACKEND_URL=http://127.0.0.1:8765
STASH_CODEX_MODE=cli
```

Optional: generate frontend config file directly from install script:

```bash
STASH_FRONTEND_CONFIG_PATH="/absolute/path/to/Backend.xcconfig" ./scripts/install_stack.sh
```

## 2) Start backend

```bash
./scripts/run_backend.sh
```

For Codex-backed planning/execution, confirm local login once:

```bash
codex login status
```

Health check:

```bash
curl http://127.0.0.1:8765/health
```

Expected:

```json
{"ok":true}
```

Integration diagnostics (Codex mode/binary/login status):

```bash
curl http://127.0.0.1:8765/health/integrations
```

## 3) Start full stack helper

```bash
./scripts/run_stack.sh
```

Behavior:

- Starts backend
- Opens an `.xcodeproj` if found in the repo (excluding `.git`, `.venv`, `backend-service`)
- If no `.xcodeproj` exists but `frontend-macos/Package.swift` exists, opens that Swift package in Xcode
- Or opens the path from `STASH_FRONTEND_PROJECT_PATH` if provided

Example:

```bash
STASH_FRONTEND_PROJECT_PATH="/absolute/path/to/App.xcodeproj" ./scripts/run_stack.sh
```

Swift Package frontend build/run:

```bash
cd frontend-macos
swift build
swift run
```

## 4) Minimal frontend boot sequence

1. `GET /health`
2. `POST /v1/projects` with selected folder path
3. Use returned `project_id` for conversation/message/run APIs
4. Subscribe to `GET /v1/projects/{project_id}/events/stream` for live updates

## 5) Verify backend quickly

```bash
./scripts/smoke_test_backend.sh
```

Codex CLI planner/executor integration test with a mocked Codex binary:

```bash
./scripts/integration_test_codex_cli_mock.sh
```

This validates project creation, history, indexing/search, tagged command run execution, and portable `.stash/` state.

## 6) Folder permissions

Backend writes portable project state under:

```text
<project_root>/.stash/
```

If selected folder is not writable, backend returns permission errors for indexing/runs.
