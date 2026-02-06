# Stash

Stash is a local-first macOS coding assistant with:

- A local backend service (`backend-service/`)
- A main workspace app (`StashMacOSApp`)
- A floating overlay app (`StashOverlay`)

The backend is the source of truth for project/session state, and both frontend surfaces sync through it.

## What Is Implemented

- Per-project local state in `PROJECT_ROOT/.stash/`
- SQLite-backed conversations/messages/runs/steps/events
- Local indexing + retrieval with watcher-driven incremental updates
- Run orchestration with planning/execution/confirmation phases
- Apply/discard flow for proposed filesystem changes
- Empty-chat quick actions (exactly 3)
- Active project sync across workspace + overlay via backend runtime config
- Chat deletion (conversation + related messages/runs/steps/events cleanup)

## Repository Layout

- `backend-service/`: FastAPI backend + tests
- `frontend-macos/`: Swift package with workspace and overlay executables
- `scripts/`: install/run/test helpers
- `docs/`: integration and installer docs

## Prerequisites

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- `swift` in `PATH`
- `python3` in `PATH` and version `>=3.11`

Important: `backend-service/pyproject.toml` requires Python `>=3.11`.  
`scripts/install_stack.sh` uses `python3`, so your default `python3` must point to 3.11+.

## Quick Start

### 1) Install backend environment

From repo root:

```bash
./scripts/install_stack.sh
```

If default `python3` is below 3.11:

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -e backend-service
pip install "uv>=0.4.30" "pypdf>=4.2.0"
```

### 2) Start backend

```bash
./scripts/run_backend.sh
```

Backend URL: `http://127.0.0.1:8765`

### 3) Start frontend app(s)

Workspace app:

```bash
cd frontend-macos
swift run StashMacOSApp
```

Overlay app:

```bash
cd frontend-macos
swift run StashOverlay
```

If you want both workspace + overlay running at once, start them in separate terminals (with backend already running).

## One-Command Launchers

From repo root:

```bash
./scripts/run_stack.sh
./scripts/run_everything.sh
```

- `run_stack.sh` starts backend and launches one frontend product.
- Default frontend product is `StashMacOSApp`.
- To launch overlay instead:

```bash
STASH_FRONTEND_PRODUCT=StashOverlay ./scripts/run_stack.sh
```

- `run_everything.sh` wraps install+run behavior:
  - `--install`: force install first
  - `--skip-install`: skip install

## Desktop App Bundle

Install:

```bash
./scripts/desktop/install_desktop_app.sh
open "$HOME/Desktop/Stash Local.app"
```

Runtime logs:

```bash
tail -f "$HOME/Library/Logs/StashLocal/backend.log"
tail -f "$HOME/Library/Logs/StashLocal/frontend.log"
tail -f "$HOME/Library/Logs/StashLocal/overlay.log"
```

See `docs/DESKTOP_INSTALLER.md` for overrides and packaging details.

## Testing

Backend unit tests:

```bash
source .venv/bin/activate
PYTHONPATH=backend-service pytest -q backend-service/tests
```

Backend smoke test:

```bash
./scripts/smoke_test_backend.sh
```

Backend Codex CLI integration test (mocked codex binary):

```bash
./scripts/integration_test_codex_cli_mock.sh
```

Frontend tests:

```bash
cd frontend-macos
swift test
```

## Troubleshooting

- Backend fails during install with Python version error:
  - Verify `python3 --version` is 3.11+ or create `.venv` manually with `python3.11`.
- Overlay is not visible:
  - `run_stack.sh` launches `StashMacOSApp` by default, not overlay.
  - Run `swift run StashOverlay` directly, or use `STASH_FRONTEND_PRODUCT=StashOverlay`.
- Runs do not execute through Codex:
  - Verify CLI auth: `codex login status`.

## Additional Docs

- `backend-service/README.md`
- `frontend-macos/README.md`
- `docs/FRONTEND_BACKEND_RUN.md`
- `docs/DESKTOP_INSTALLER.md`

## License

TBD
