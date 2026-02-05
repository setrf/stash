#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TARGET_DIR="${STASH_DESKTOP_TARGET_DIR:-$HOME/Desktop}"
APP_NAME="${STASH_DESKTOP_APP_NAME:-Stash Local.app}"
APP_BUNDLE="$TARGET_DIR/$APP_NAME"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"

BACKEND_URL="${STASH_BACKEND_URL:-http://127.0.0.1:8765}"
RUNTIME_BASE="${STASH_RUNTIME_BASE:-$HOME/Library/Application Support/StashLocal/runtime}"
BACKEND_VENV="$RUNTIME_BASE/.venv"
BACKEND_CODEX_MODE="${STASH_CODEX_MODE:-cli}"
ICON_SOURCE="${STASH_ICON_SOURCE:-$ROOT_DIR/frontend-macos/Resources/AppIcon-source.png}"
ICON_ICNS="${STASH_ICON_ICNS:-$ROOT_DIR/frontend-macos/Resources/AppIcon.icns}"
BACKEND_CODEX_BIN=""

log() {
  printf '[stash-installer] %s\n' "$1"
}

find_frontend_release_binary() {
  local candidate
  candidate=""

  if [ -x "$ROOT_DIR/frontend-macos/.build/release/StashMacOSApp" ]; then
    candidate="$ROOT_DIR/frontend-macos/.build/release/StashMacOSApp"
  fi

  if [ -z "$candidate" ]; then
    candidate="$(find "$ROOT_DIR/frontend-macos/.build" -type f -name 'StashMacOSApp' -perm -u+x 2>/dev/null | grep '/release/' | head -n 1 || true)"
  fi

  printf '%s' "$candidate"
}

resolve_codex_binary() {
  if [ -n "${STASH_CODEX_BIN:-}" ] && [ -x "${STASH_CODEX_BIN:-}" ]; then
    printf '%s' "${STASH_CODEX_BIN:-}"
    return
  fi

  if command -v codex >/dev/null 2>&1; then
    command -v codex
    return
  fi

  for candidate in /opt/homebrew/bin/codex /usr/local/bin/codex "$HOME/.local/bin/codex"; do
    if [ -x "$candidate" ]; then
      printf '%s' "$candidate"
      return
    fi
  done

  printf '%s' "codex"
}

if [ ! -d "$ROOT_DIR/frontend-macos" ]; then
  echo "frontend-macos folder is missing. Cannot build desktop app." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "swift is required to build frontend-macos" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to build backend runtime" >&2
  exit 1
fi

BACKEND_CODEX_BIN="$(resolve_codex_binary)"
log "Using Codex CLI binary: $BACKEND_CODEX_BIN"

log "Preparing backend runtime at $BACKEND_VENV"
mkdir -p "$RUNTIME_BASE"
python3 -m venv "$BACKEND_VENV"
# shellcheck disable=SC1091
source "$BACKEND_VENV/bin/activate"
python -m pip install --upgrade pip
python -m pip install "$ROOT_DIR/backend-service"

if ! command -v uv >/dev/null 2>&1; then
  python -m pip install "uv>=0.4.30"
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "Failed to provision required CLI tool: uv" >&2
  exit 1
fi

PYPDF_VERSION="$(python - <<'PY'
import pypdf
print(pypdf.__version__)
PY
)"

log "Backend toolchain ready (uv: $(command -v uv), pypdf: $PYPDF_VERSION)"

deactivate >/dev/null 2>&1 || true

log "Building frontend release binary"
(
  cd "$ROOT_DIR/frontend-macos"
  swift build -c release --product StashMacOSApp
)

if [ -f "$ICON_SOURCE" ]; then
  log "Building app icon from $ICON_SOURCE"
  STASH_ICON_SOURCE="$ICON_SOURCE" STASH_ICNS_OUT="$ICON_ICNS" "$ROOT_DIR/scripts/desktop/build_icns.sh"
else
  log "Icon source not found at $ICON_SOURCE; keeping default app icon"
fi

FRONTEND_BIN="$(find_frontend_release_binary)"
if [ -z "$FRONTEND_BIN" ] || [ ! -x "$FRONTEND_BIN" ]; then
  echo "Could not locate built frontend binary." >&2
  exit 1
fi

log "Creating desktop app bundle at $APP_BUNDLE"
python3 - <<PY
from pathlib import Path
import shutil

app = Path(r'''$APP_BUNDLE''')
if app.exists():
    shutil.rmtree(app)
(app / 'Contents' / 'MacOS').mkdir(parents=True, exist_ok=True)
(app / 'Contents' / 'Resources').mkdir(parents=True, exist_ok=True)
PY

cp "$FRONTEND_BIN" "$APP_RESOURCES/StashMacOSApp"
chmod +x "$APP_RESOURCES/StashMacOSApp"
if [ -f "$ICON_ICNS" ]; then
  cp "$ICON_ICNS" "$APP_RESOURCES/AppIcon.icns"
fi

cat > "$APP_CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Stash Local</string>
  <key>CFBundleDisplayName</key>
  <string>Stash Local</string>
  <key>CFBundleIdentifier</key>
  <string>com.stash.local.desktop</string>
  <key>CFBundleVersion</key>
  <string>2</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>StashDesktopLauncher</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <false/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

cat > "$APP_RESOURCES/launcher.conf" << EOF_CONF
STASH_BACKEND_VENV="$BACKEND_VENV"
STASH_BACKEND_URL="$BACKEND_URL"
STASH_CODEX_MODE="$BACKEND_CODEX_MODE"
STASH_CODEX_BIN="$BACKEND_CODEX_BIN"
EOF_CONF

cat > "$APP_MACOS/StashDesktopLauncher" << 'EOF_LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RES_DIR="$(cd "$SCRIPT_DIR/../Resources" && pwd)"
CONF_PATH="$RES_DIR/launcher.conf"
FRONTEND_BIN="$RES_DIR/StashMacOSApp"

if [ ! -f "$CONF_PATH" ]; then
  osascript -e 'display alert "Stash Local" message "Launcher config missing. Re-run installer." as critical'
  exit 1
fi

# shellcheck source=/dev/null
source "$CONF_PATH"

LOG_DIR="$HOME/Library/Logs/StashLocal"
STATE_DIR="$HOME/Library/Application Support/StashLocal"
BACKEND_PID_FILE="$STATE_DIR/backend.pid"
mkdir -p "$LOG_DIR" "$STATE_DIR"
export PATH="$STASH_BACKEND_VENV/bin:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH"
if [ -n "${STASH_CODEX_BIN:-}" ]; then
  CODEX_DIR="$(dirname "$STASH_CODEX_BIN")"
  if [ -d "$CODEX_DIR" ]; then
    export PATH="$CODEX_DIR:$PATH"
  fi
fi

health_ok() {
  curl -fsS "$STASH_BACKEND_URL/health" >/dev/null 2>&1
}

backend_started_by_launcher=0

if ! health_ok; then
  if [ ! -x "$STASH_BACKEND_VENV/bin/python" ]; then
    osascript -e 'display alert "Stash Local" message "Missing backend runtime. Re-run installer." as critical'
    exit 1
  fi

  nohup env STASH_CODEX_MODE="$STASH_CODEX_MODE" STASH_CODEX_BIN="${STASH_CODEX_BIN:-codex}" PATH="$PATH" \
    "$STASH_BACKEND_VENV/bin/python" -m uvicorn stash_backend.main:app --host 127.0.0.1 --port 8765 \
    >"$LOG_DIR/backend.log" 2>&1 &

  BACKEND_PID=$!
  echo "$BACKEND_PID" > "$BACKEND_PID_FILE"
  backend_started_by_launcher=1

  for _ in $(seq 1 120); do
    if health_ok; then
      break
    fi
    sleep 0.25
  done
fi

if ! health_ok; then
  osascript -e 'display alert "Stash Local" message "Backend failed to start. Check ~/Library/Logs/StashLocal/backend.log" as critical'
  exit 1
fi

if [ ! -x "$FRONTEND_BIN" ]; then
  osascript -e 'display alert "Stash Local" message "Frontend binary missing. Re-run installer." as critical'
  exit 1
fi

export STASH_BACKEND_URL
export STASH_CODEX_MODE
export STASH_CODEX_BIN
"$FRONTEND_BIN" >>"$LOG_DIR/frontend.log" 2>&1 || true

if [ "$backend_started_by_launcher" -eq 1 ] && [ -f "$BACKEND_PID_FILE" ]; then
  pid="$(cat "$BACKEND_PID_FILE" 2>/dev/null || true)"
  if [ -n "$pid" ]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$BACKEND_PID_FILE"
fi
EOF_LAUNCHER

chmod +x "$APP_MACOS/StashDesktopLauncher"

log "Desktop app installed"
log "- App: $APP_BUNDLE"
log "- Backend runtime: $BACKEND_VENV"
log "- Backend URL: $BACKEND_URL"
log "Double-click the app on Desktop to start backend + frontend."
