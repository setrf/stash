#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV_DIR="$ROOT_DIR/.venv"

if [ ! -d "$VENV_DIR" ]; then
  echo "Missing virtualenv. Run ./scripts/install_stack.sh first." >&2
  exit 1
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
exec uvicorn stash_backend.main:app --host 127.0.0.1 --port 8765
