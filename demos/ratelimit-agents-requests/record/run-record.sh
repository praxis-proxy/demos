#!/usr/bin/env bash
# Bring up the recording stack (deterministic mock model + access_log) and drop
# into the interactive agent REPL. This is the stack record_demo.py drives for the
# recording; run it directly to rehearse the acts by hand.
#
# The recording is deterministic (mock model with prepared replies) — the
# committed proof of the policy outcomes is still ../run-demo.sh.
#
# Prereqs: everything run-demo.sh needs, plus python httpx (and asciinema for the
# actual capture): pip install -r record/requirements.txt into record/.venv.
#
# Usage (from the demo root or this directory):
#   ./record/run-record.sh
set -euo pipefail
cd "$(dirname "$0")/.."   # demo root

GATEWAY_LOG="record/gateway-record.log"
export RUST_LOG="${RUST_LOG:-info}"
PY="record/.venv/bin/python"; [ -x "$PY" ] || PY="python3"

step() { printf "\n\033[1;34m[record]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
die()  { printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

GW_PID=""
cleanup() {
  [ -n "$GW_PID" ] && kill "$GW_PID" 2>/dev/null || true
  docker compose down >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_port() {  # host port timeout
  local host="$1" port="$2" timeout="${3:-30}" i=0
  while ! (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null; do
    i=$((i + 1)); [ "$i" -ge "$timeout" ] && return 1; sleep 1
  done
  exec 3>&- 2>/dev/null || true
  return 0
}

for tool in docker cargo python3 openssl curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
"$PY" -c "import httpx" 2>/dev/null \
  || die "python 'httpx' not available ($PY) — pip install -r record/requirements.txt"

step "generating agent tokens and JWKS"
./jwt/generate.sh >/dev/null
ok "agent-blue, agent-green, nosub + jwks.json"

step "starting sidecars (jwt-issuer + mock model)"
docker compose up -d --wait >/dev/null
ok "jwt-issuer :8888 and mock-model :9100 healthy"

step "building/resolving the Praxis binary"
GATEWAY_BIN="$(./build-praxis.sh)"
[ -x "$GATEWAY_BIN" ] || die "praxis binary not found at '$GATEWAY_BIN'"
ok "$GATEWAY_BIN"

step "launching gateway on :8095 (access_log on, backend = mock model)"
nohup "$GATEWAY_BIN" -c record/praxis-record.yaml > "$GATEWAY_LOG" 2>&1 & GW_PID=$!
wait_port 127.0.0.1 8095 30 || die "gateway did not start (see $GATEWAY_LOG)"
ok "gateway listening (log: $GATEWAY_LOG)"

step "entering the agent REPL (type /help; /quit to exit)"
echo
GATEWAY_URL="http://127.0.0.1:8095" TOKENS_DIR="jwt/tokens" MODEL="mock-model" \
  "$PY" record/agent-repl.py
