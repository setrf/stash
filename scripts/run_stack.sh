#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend-macos"

cleanup() {
  if [[ -n "${BACKEND_PID:-}" ]]; then
    kill "$BACKEND_PID" >/dev/null 2>&1 || true
    wait "$BACKEND_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

"$ROOT_DIR/scripts/run_backend.sh" &
BACKEND_PID=$!

sleep 1

echo "Backend running on http://127.0.0.1:8765 (pid=$BACKEND_PID)"

if compgen -G "$FRONTEND_DIR/*.xcodeproj" >/dev/null; then
  XCODEPROJ=$(ls "$FRONTEND_DIR"/*.xcodeproj | head -n 1)
  echo "Opening frontend project: $XCODEPROJ"
  open "$XCODEPROJ"
else
  echo "No frontend Xcode project found in $FRONTEND_DIR"
  echo "Backend stays running. Press Ctrl+C to stop."
fi

wait "$BACKEND_PID"
