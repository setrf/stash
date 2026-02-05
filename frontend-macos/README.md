# Frontend Integration (macOS)

This folder is reserved for the SwiftUI/AppKit app.

## Backend URL

Use the generated config:

- Config file: `frontend-macos/Config/Backend.xcconfig`
- Value: `STASH_BACKEND_URL=http://127.0.0.1:8765`

## One-command local setup

Run from repo root:

```bash
./scripts/install_stack.sh
```

This installs backend dependencies and writes frontend backend-url config.

## Suggested app behavior

1. On app launch, start backend via `scripts/run_backend.sh` (or bundle an equivalent launcher inside the app).
2. Read `STASH_BACKEND_URL` from `Backend.xcconfig`.
3. Health-check `GET /health` before enabling chat and project actions.
