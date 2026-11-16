#!/usr/bin/env bash
# End-to-end rate-limit demo: build Praxis from source (core `praxis`, v0.8.0),
# run it in front of a mock model, and prove the six walkthrough beats with real
# agent tokens. Exits nonzero on any unexpected outcome.
#
# Context: an AI agent calls a shared model through the gateway; the gateway caps
# how often each agent may call it, keyed on the agent's verified identity.
#
# Topology:
#   * jwt-issuer + mock-model run in docker-compose (sidecars).
#   * Praxis runs on the HOST, built by ./build-praxis.sh.
#
# This is the DETERMINISTIC path: the model is mocked (canned completions) and the
# "agent" is this script. Counters are in-memory and live for the 60s window, so
# the checks are sequenced to keep each agent/route counter in a known state (only
# the mock model's served-request counter is reset, to measure dispatch per phase).
#
# Requirements: docker (compose), cargo, python3, openssl, curl, jq.
#
# Usage:
#   ./run-demo.sh
set -euo pipefail
cd "$(dirname "$0")"

GW="http://127.0.0.1:8095"
MODEL="http://127.0.0.1:9100"
GATEWAY_LOG="gateway.log"
export RUST_LOG="${RUST_LOG:-info}"

step() { printf "\n\033[1;34m[ratelimit]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
info() { printf "  %s\n" "$*"; }
warn() { printf "  \033[1;33m! %s\033[0m\n" "$*"; }
die()  { printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

fails=0
bad() { printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2; fails=$((fails + 1)); }

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

# gw <method> <path> <token> [extra-header] -> prints the HTTP status code.
gw() {
  local method="$1" path="$2" token="$3" hdr="${4:-}"
  local args=(-s -o /dev/null -w '%{http_code}' -X "$method" "${GW}${path}")
  [ -n "$token" ] && args+=(-H "Authorization: Bearer ${token}")
  [ -n "$hdr" ] && args+=(-H "$hdr")
  [ "$method" = "POST" ] && args+=(-H "Content-Type: application/json" -d '{}')
  curl "${args[@]}" || echo "000"
}

served()       { curl -s "${MODEL}/__count" | jq -r '.served'; }
reset_served() { curl -s -X POST "${MODEL}/__reset" >/dev/null; }

# expect <label> <actual> <expected>
expect() {
  if [ "$2" = "$3" ]; then ok "$1 → $2"; else bad "$1 → got '$2', expected '$3'"; fi
}

# ---------------------------------------------------------------------------
for tool in docker cargo python3 openssl curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# 1. Agent tokens + JWKS (must exist before compose mounts jwks.json).
step "generating agent tokens and JWKS"
./jwt/generate.sh >/dev/null
ok "agent-blue, agent-green, nosub + jwks.json"

# 2. Sidecars (jwt-issuer, mock model) with health gates.
step "starting sidecars (docker compose)"
docker compose up -d --wait >/dev/null
ok "jwt-issuer :8888 and mock-model :9100 healthy"

# 3. Build + launch Praxis on the host.
step "building/resolving the Praxis binary (first run ~5-10 min)"
GATEWAY_BIN="$(./build-praxis.sh)"
[ -x "$GATEWAY_BIN" ] || die "praxis binary not found at '$GATEWAY_BIN'"
ok "$GATEWAY_BIN"

step "launching gateway on :8095"
nohup "$GATEWAY_BIN" -c praxis.yaml > "$GATEWAY_LOG" 2>&1 & GW_PID=$!
wait_port 127.0.0.1 8095 30 || die "gateway did not start (see $GATEWAY_LOG)"
ok "gateway listening (log: $GATEWAY_LOG)"

# 4. Load agent tokens.
BLUE="$(cat jwt/tokens/agent-blue.jwt)"
GREEN="$(cat jwt/tokens/agent-green.jwt)"
NOSUB="$(cat jwt/tokens/nosub.jwt)"

# ---------------------------------------------------------------------------
# Walkthrough verification. /v1/chat/completions = 3/60s per agent;
# /v1/embeddings = 1/60s per agent; /v1/models = no limiter.
# ---------------------------------------------------------------------------

step "#1 Accounting — admitted model calls advance agent-blue's counter"
reset_served
expect "agent-blue chat (1/3)" "$(gw POST /v1/chat/completions "$BLUE")" 200
expect "agent-blue chat (2/3)" "$(gw POST /v1/chat/completions "$BLUE")" 200
expect "agent-blue chat (3/3)" "$(gw POST /v1/chat/completions "$BLUE")" 200
expect "model served 3 inferences" "$(served)" 3

step "#2 Admission gate — the call that would exceed is denied, no dispatch"
expect "agent-blue chat (over limit) → 429" "$(gw POST /v1/chat/completions "$BLUE")" 429
expect "no new inference after the 429" "$(served)" 3

step "#3 Identity-based keying — agent-green's budget is its own"
reset_served
expect "agent-green chat (1/3) while agent-blue throttled" "$(gw POST /v1/chat/completions "$GREEN")" 200
expect "agent-green chat (2/3)" "$(gw POST /v1/chat/completions "$GREEN")" 200
expect "agent-green chat (3/3)" "$(gw POST /v1/chat/completions "$GREEN")" 200
expect "model served agent-green's 3 inferences" "$(served)" 3
expect "agent-green chat (its own limit) → 429" "$(gw POST /v1/chat/completions "$GREEN")" 429
expect "agent-blue still throttled → 429" "$(gw POST /v1/chat/completions "$BLUE")" 429

step "#4 Selection — /v1/models carries no limiter"
reset_served
for i in 1 2 3 4 5; do
  expect "agent-blue GET /v1/models ($i/5)" "$(gw GET /v1/models "$BLUE")" 200
done
expect "all 5 reached the model" "$(served)" 5

step "#5 Route-specific limit — /v1/embeddings has a lower allowance"
reset_served
expect "agent-blue embeddings (1/1)" "$(gw POST /v1/embeddings "$BLUE")" 200
expect "agent-blue embeddings (over limit after 1) → 429" "$(gw POST /v1/embeddings "$BLUE")" 429
expect "only 1 reached the model on /v1/embeddings" "$(served)" 1

step "#6 Trust basis — rate limiting requires a verified agent identity"
reset_served
expect "no Authorization header → 401" "$(gw POST /v1/chat/completions '')" 401
expect "nosub token (valid, no subject) → 401 (ratelimit.no_identity)" "$(gw POST /v1/chat/completions "$NOSUB")" 401
expect "no inference served for the denied calls" "$(served)" 0

step "gateway log confirms the policy filter performed the denials"
# At info level the gateway logs each denial as `rejected by filter
# filter="policy" status=<code>`. The fine-grained ratelimit.* reason codes are
# operator-log/debug detail; the client-facing contract is the HTTP status.
rejlog="$(sed 's/\x1b\[[0-9;]*m//g' "$GATEWAY_LOG" 2>/dev/null)"
printf '%s\n' "$rejlog" | grep -q 'rejected by filter.*filter="policy".*status=429' \
  && ok "policy filter rejected with 429 (over-limit)" \
  || warn "no policy 429 line in $GATEWAY_LOG (RUST_LOG?)"
printf '%s\n' "$rejlog" | grep -q 'rejected by filter.*filter="policy".*status=401' \
  && ok "policy filter rejected with 401 (missing/empty identity)" \
  || warn "no policy 401 line in $GATEWAY_LOG (RUST_LOG?)"

# ---------------------------------------------------------------------------
echo
if [ "$fails" -eq 0 ]; then
  printf "\033[1;32mAll rate-limit checks passed.\033[0m\n"
else
  die "$fails check(s) failed — see $GATEWAY_LOG"
fi
