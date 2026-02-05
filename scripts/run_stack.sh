#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_PROJECT_PATH="${STASH_FRONTEND_PROJECT_PATH:-}"
FRONTEND_DIR="$ROOT_DIR/frontend-macos"
FRONTEND_LAUNCH_MODE="${STASH_FRONTEND_LAUNCH_MODE:-run}"

cleanup() {
  if [[ -n "${FRONTEND_PID:-}" ]]; then
    kill "$FRONTEND_PID" >/dev/null 2>&1 || true
    wait "$FRONTEND_PID" >/dev/null 2>&1 || true
  fi
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

if [ -n "$FRONTEND_PROJECT_PATH" ] && [ -d "$FRONTEND_PROJECT_PATH" ]; then
  echo "Opening frontend project: $FRONTEND_PROJECT_PATH"
  open "$FRONTEND_PROJECT_PATH"
  wait "$BACKEND_PID"
else
  XCODEPROJ="$(find "$FRONTEND_DIR" -maxdepth 2 -type d -name '*.xcodeproj' | head -n 1)"
  FRONTEND_PACKAGE=""
  if [ -f "$FRONTEND_DIR/Package.swift" ]; then
    FRONTEND_PACKAGE="$FRONTEND_DIR/Package.swift"
  fi

  if [ -n "$FRONTEND_PACKAGE" ] && [ "$FRONTEND_LAUNCH_MODE" = "run" ]; then
    if ! command -v swift >/dev/null 2>&1; then
      echo "swift command not found; cannot run frontend package directly."
      echo "Falling back to opening project/package."
      FRONTEND_LAUNCH_MODE="open"
    else
      echo "Launching frontend app from Swift package: $FRONTEND_PACKAGE"
      (
        cd "$FRONTEND_DIR"
        swift run
      ) &
      FRONTEND_PID=$!
      wait "$FRONTEND_PID"
      exit 0
    fi
  fi

  if [ -n "$XCODEPROJ" ]; then
    echo "Opening frontend project in frontend-macos: $XCODEPROJ"
    open "$XCODEPROJ"
    wait "$BACKEND_PID"
  elif [ -n "$FRONTEND_PACKAGE" ]; then
    echo "Opening frontend Swift package in frontend-macos: $FRONTEND_PACKAGE"
    open "$FRONTEND_PACKAGE"
    wait "$BACKEND_PID"
  else
    echo "No frontend project found in frontend-macos."
    echo "Set STASH_FRONTEND_PROJECT_PATH to an explicit .xcodeproj if needed."
    echo "Backend stays running. Press Ctrl+C to stop."
    wait "$BACKEND_PID"
  fi
fi
