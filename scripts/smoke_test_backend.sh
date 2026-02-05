#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="http://127.0.0.1:8765"
PROJECT_ROOT="/tmp/stash-smoke-project"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [ ! -d "$ROOT_DIR/.venv" ]; then
  echo "Missing virtualenv. Run ./scripts/install_stack.sh first." >&2
  exit 1
fi

rm -rf "$PROJECT_ROOT"
mkdir -p "$PROJECT_ROOT"

# shellcheck disable=SC1091
source "$ROOT_DIR/.venv/bin/activate"

uvicorn stash_backend.main:app --host 127.0.0.1 --port 8765 >/tmp/stash-smoke-server.log 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 40); do
  if curl -fsS "$API_URL/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! curl -fsS "$API_URL/health" >/dev/null 2>&1; then
  echo "Backend failed health check; server log:" >&2
  sed -n '1,200p' /tmp/stash-smoke-server.log >&2
  exit 1
fi

echo "[1/8] create project"
PROJECT_JSON=$(curl -fsS -X POST "$API_URL/v1/projects" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"Smoke Project\",\"root_path\":\"$PROJECT_ROOT\"}")
PROJECT_ID=$(python -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<< "$PROJECT_JSON")


echo "[2/8] list conversations"
CONVS_JSON=$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/conversations")
CONV_ID=$(python -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["id"])' <<< "$CONVS_JSON")


echo "[3/8] add note asset and index"
curl -fsS -X POST "$API_URL/v1/projects/$PROJECT_ID/assets" \
  -H 'Content-Type: application/json' \
  -d '{"kind":"note","title":"Kickoff","content":"Backend smoke test note for indexing and retrieval.","tags":["smoke"],"auto_index":true}' >/dev/null


echo "[4/8] search retrieval"
SEARCH_JSON=$(curl -fsS -X POST "$API_URL/v1/projects/$PROJECT_ID/search" \
  -H 'Content-Type: application/json' \
  -d '{"query":"smoke retrieval note","limit":5}')
python -c 'import json,sys; data=json.load(sys.stdin); assert "hits" in data; print(len(data["hits"]))' <<< "$SEARCH_JSON" >/tmp/stash-smoke-hit-count.txt


echo "[5/8] send conversation message + run"
TASK_JSON=$(curl -fsS -X POST "$API_URL/v1/projects/$PROJECT_ID/conversations/$CONV_ID/messages" \
  -H 'Content-Type: application/json' \
  -d '{"role":"user","content":"<codex_cmd>\nworktree: smoke\ncmd: pwd\n</codex_cmd>","start_run":true,"mode":"manual"}')
RUN_ID=$(python -c 'import json,sys; print(json.load(sys.stdin)["run_id"])' <<< "$TASK_JSON")


echo "[6/8] wait for run completion"
for _ in $(seq 1 80); do
  RUN_JSON=$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/runs/$RUN_ID")
  RUN_STATUS=$(python -c 'import json,sys; print(json.load(sys.stdin)["status"])' <<< "$RUN_JSON")
  if [[ "$RUN_STATUS" == "done" || "$RUN_STATUS" == "failed" || "$RUN_STATUS" == "cancelled" ]]; then
    break
  fi
  sleep 0.25
done

if [[ "$RUN_STATUS" != "done" ]]; then
  echo "Run did not complete successfully: $RUN_STATUS" >&2
  echo "$RUN_JSON" >&2
  exit 1
fi


echo "[7/8] verify message history and timeline"
MSGS_JSON=$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/conversations/$CONV_ID/messages")
python -c 'import json,sys; data=json.load(sys.stdin); assert len(data) >= 2; print(len(data))' <<< "$MSGS_JSON" >/tmp/stash-smoke-msg-count.txt

HISTORY_JSON=$(curl -fsS "$API_URL/v1/projects/$PROJECT_ID/history")
python -c 'import json,sys; data=json.load(sys.stdin); assert "items" in data and len(data["items"]) > 0; print(len(data["items"]))' <<< "$HISTORY_JSON" >/tmp/stash-smoke-history-count.txt


echo "[8/8] verify portable project state"
[ -f "$PROJECT_ROOT/.stash/project.json" ]
[ -f "$PROJECT_ROOT/.stash/stash.db" ]
[ -d "$PROJECT_ROOT/.stash/worktrees" ]
[ -f "$PROJECT_ROOT/STASH_HISTORY.md" ]
grep -q "run_completed" "$PROJECT_ROOT/STASH_HISTORY.md"

HITS=$(cat /tmp/stash-smoke-hit-count.txt)
MSGS=$(cat /tmp/stash-smoke-msg-count.txt)
EVENTS=$(cat /tmp/stash-smoke-history-count.txt)

echo "Smoke test passed"
echo "project_id=$PROJECT_ID"
echo "conversation_id=$CONV_ID"
echo "run_id=$RUN_ID"
echo "search_hits=$HITS"
echo "messages=$MSGS"
echo "history_items=$EVENTS"
