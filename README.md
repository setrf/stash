# Stash

Stash is a macOS menu bar app that lets you quickly capture PDFs, notes, questions, and highlighted text into **Projects**, then generates **grounded insights**, **follow‑up questions**, and **answers** using OpenAI’s Responses API with File Search (vector stores). It is **BYOK (bring your own OpenAI API key)** for the MVP and stores your originals and derived artifacts locally, with per‑project control over what’s uploaded.

## Why Stash
- Capture becomes effortless.
- Project context becomes coherent.
- Answers are grounded in your materials.
- Insight generation happens automatically, but stays controllable.

## MVP Scope
- macOS menu bar app with an always‑on‑top overlay
- Project creation and fast Project switching
- Drag‑and‑drop PDFs into the overlay
- Quick note / question input
- Capture selected text via “save clipboard” hotkey
- Automatic processing on new inputs (configurable)
- Project‑scoped Q&A chat
- Project window to browse inputs, outputs, and activity
- Feedback on outputs (thumbs up/down)
- Settings: API key, per‑project upload toggle, concurrency, notifications

## Core Objects
- **Projects**: the primary container
- **Inputs**: PDFs, notes, questions, snippets
- **Outputs**: brief, insights, open questions, suggested questions, action items, answers
- **Runs**: background jobs that ingest and generate outputs

## High‑Level Architecture
- **UI (SwiftUI/AppKit)**: menu bar, overlay, Projects window
- **Local data layer**: SQLite or Core Data
- **File storage**: `~/Library/Application Support/Stash/Projects/<project_id>/`
- **Background worker**: PDF extraction, chunking, indexing, Responses calls
- **OpenAI stack**: Responses API + File Search (vector stores), optional Agents SDK

## Output Expectations (Structured)
- **Project brief**: summary, objectives, constraints, stakeholders, assumptions, unknowns
- **Key insights**: statements with confidence + evidence
- **Open questions**: grouped by theme
- **Suggested next questions**: “ask this next” list
- **Action items**: decisions, next steps, agenda
- **Q&A answers**: grounded answer + sources + missing info

## Principles
- Local‑first: originals and outputs stored locally
- Grounded: answers only from project materials
- Transparent: clear processing and upload controls
- Fast: overlay appears instantly, results stream quickly

## Status
Backend foundation is now implemented under `backend-service/`:

- FastAPI local service on `localhost`
- Folder-scoped project state in `.stash/` for portable resume/history
- SQLite metadata + conversations/runs/events
- Local vector indexing/search
- Background file watching/indexing
- Tagged Codex command execution in controlled worktrees

See `backend-service/README.md` for setup and API usage.

## One Install For Frontend + Backend

From repo root:

```bash
./scripts/install_stack.sh
```

This does a single local setup for the stack:

- Creates `.venv/`
- Installs backend dependencies
- Installs required runtime tools (including `uv`) and document packages (including `pypdf`) into the backend environment
- Uses app-managed runtime configuration (no `.env` setup required)
- Optionally writes frontend config when `STASH_FRONTEND_CONFIG_PATH` is set

## Install Desktop App From Scratch (macOS)

Use this when you want a local `.app` bundle (menu bar overlay + workspace window) instead of running backend/frontend in separate terminals.

Prerequisites:
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- `python3` and `swift` available in `PATH`

From repo root:

```bash
./scripts/desktop/install_desktop_app.sh
```

What this installer does:
- Creates a dedicated backend runtime at `~/Library/Application Support/StashLocal/runtime/.venv`
- Installs backend package and runtime tools (including `uv` and `pypdf`)
- Builds frontend release binaries (`StashMacOSApp` and `StashOverlay`)
- Installs `Stash Local.app` to `~/Desktop` by default

Launch the app:

```bash
open "$HOME/Desktop/Stash Local.app"
```

Optional installer overrides:

```bash
STASH_DESKTOP_TARGET_DIR="/Applications" \
STASH_DESKTOP_APP_NAME="Stash Local.app" \
STASH_BACKEND_URL="http://127.0.0.1:8765" \
STASH_CODEX_MODE="cli" \
./scripts/desktop/install_desktop_app.sh
```

Reinstall after updates:

```bash
./scripts/desktop/install_desktop_app.sh
```

Useful logs:
- `~/Library/Logs/StashLocal/backend.log`
- `~/Library/Logs/StashLocal/frontend.log`
- `~/Library/Logs/StashLocal/overlay.log`

## One Command To Run Everything

From repo root:

```bash
./scripts/run_everything.sh
```

This single command:
- Runs install automatically if `.venv/` does not exist
- Starts backend + frontend stack

Optional flags:
- `--install` force reinstall before run
- `--skip-install` skip install and only run

If you are one level above the repo (`New project/`), use:

```bash
./run_stash.sh
```

Run commands:

```bash
./scripts/run_backend.sh
./scripts/run_stack.sh
./scripts/run_everything.sh
./scripts/smoke_test_backend.sh
./scripts/integration_test_codex_cli_mock.sh
```

Equivalent `make` targets:

```bash
make install
make run-backend
make run-stack
make run-everything
make smoke-test
make integration-test-codex-cli
make install-desktop
```

Frontend run/integration notes:
- `docs/FRONTEND_BACKEND_RUN.md`
- `frontend-macos/README.md`
- `docs/DESKTOP_INSTALLER.md`

Codex requirement:
- Run `codex login status` once before using chat runs so planner/executor can use local Codex CLI.
- Open **AI Setup** in the frontend to configure planner mode and optional OpenAI API fallback.

## License
TBD
