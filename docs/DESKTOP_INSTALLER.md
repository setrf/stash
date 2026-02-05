# Desktop Installer (Backend + Frontend)

This installs a desktop app bundle that launches both backend and frontend locally.

## Install

From repo root:

```bash
./scripts/desktop/install_desktop_app.sh
```

Default output app:

```text
~/Desktop/Stash Local.app
```

Optional overrides:

```bash
STASH_DESKTOP_TARGET_DIR="/Applications" \
STASH_DESKTOP_APP_NAME="Stash Local.app" \
STASH_BACKEND_URL="http://127.0.0.1:8765" \
STASH_CODEX_MODE="cli" \
./scripts/desktop/install_desktop_app.sh
```

OpenAI/Codex planner settings are configured from the app UI in **AI Setup** after launch.

## App Icon

Default icon source image:

```text
frontend-macos/Resources/AppIcon-source.png
```

Installer converts this to `.icns` and embeds it in the app bundle.

You can override icon source:

```bash
STASH_ICON_SOURCE="/absolute/path/to/icon.png" ./scripts/desktop/install_desktop_app.sh
```

## Run

Double-click the installed app bundle (for example on Desktop).

For Codex-backed planning/execution, ensure your local CLI is authenticated once:

```bash
codex login status
```

What it does on launch:

1. Starts backend from a dedicated runtime if it is not already running
2. Waits for backend health check
3. Launches frontend app binary
4. Stops backend on app exit only if this launcher started it

Installer also provisions backend runtime CLI/tools and document packages (including `uv` and `pypdf`) inside:

The installed app does not execute from your repo path at runtime.
It uses a backend runtime in:

```text
~/Library/Application Support/StashLocal/runtime/.venv
```

## Logs

```text
~/Library/Logs/StashLocal/backend.log
~/Library/Logs/StashLocal/frontend.log
```

## Reinstall

Run installer again. It rebuilds frontend release and replaces the app bundle.
