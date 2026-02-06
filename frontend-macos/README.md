# Stash macOS Frontend

Codex-style light-mode desktop UI for Stash.

## What is implemented

- Clean Codex-style light desktop layout (project picker, 3-pane explorer/workspace/chat)
- VS Code-like file opening in the workspace:
  - Tree mode single-click opens a preview tab
  - Tree mode double-click opens/pins a regular tab
  - Opening a different file as preview auto-pins the previous preview tab to keep multiple tabs visible
  - Fallback always available via right-click: `Open Preview` / `Open Pinned`
- Automatic project onboarding:
  - If no project is open, user picks folder with the button in the UI
  - Last opened folder is restored automatically on next launch (if still available)
- Automatic indexing:
  - Project indexing is triggered automatically every time a project is opened
- File browser for current project root
- Automatic file polling for the active project:
  - New/removed files in the folder tree are reflected in the UI automatically
  - File changes trigger incremental re-index requests (`full_scan: false`)
- Conversation switcher and message timeline
- Composer to send work requests to backend
- Run polling and status display
- Optimistic user messages (your sent message appears immediately)
- Live run feedback panel:
  - Thinking status
  - Planning summary
  - Todo list from run steps as they execute
- `@file` mentions in composer:
  - Type `@` to get file suggestions from current project
  - Mentioned files are attached as structured file context parts for planning

## Backend integration

The app expects the backend service at:

- `http://127.0.0.1:8765` by default

Runtime AI configuration is managed inside the app via **AI Setup**:

- Planner backend (`auto`, `codex_cli`, `openai_api`)
- Codex CLI binary/model/login checks
- Optional OpenAI API key fallback
- Settings persisted by backend in local runtime config file

## Build and run

From repo root:

```bash
./scripts/install_stack.sh
./scripts/run_backend.sh
```

In another terminal:

```bash
cd frontend-macos
swift build
swift run
```

Or open in Xcode:

```bash
open frontend-macos/Package.swift
```

One-command backend + frontend launcher from repo root:

```bash
./scripts/run_stack.sh
```

## Install As Desktop App (macOS, from scratch)

From repo root:

```bash
./scripts/desktop/install_desktop_app.sh
```

Then launch:

```bash
open "$HOME/Desktop/Stash Local.app"
```

This installs a self-contained local app that starts backend + overlay/workspace UI together.
For full installer details and overrides, see `docs/DESKTOP_INSTALLER.md`.

## Main files

- `Sources/StashMacOSApp/StashMacOSApp.swift`
- `Sources/StashMacOSApp/RootView.swift`
- `Sources/StashMacOSApp/AppViewModel.swift`
- `Sources/StashMacOSApp/BackendClient.swift`
