#!/usr/bin/env bash
# End-to-end demo: transpile a Kuadrant AuthPolicy into a Praxis generic-HTTP
# (L7) CEL policy, run it on Praxis + CPEX against a local Keycloak, and prove
# the CEL decisions with real persona tokens.
#
# Self-contained: Keycloak (docker-compose.yml), token minting (mint-token.sh),
# and the Praxis build (build-praxis.sh) all live in this directory. Praxis
# runs on the HOST (built with the cpex-policy-engine feature); only Keycloak
# runs in Docker.
#
# Requirements: docker (compose), cargo, python3, curl, jq.
#
# Usage:
#   ./run-demo.sh
#
# Env passthrough to build-praxis.sh: PRAXIS_BIN / PRAXIS_DIR /
# PRAXIS_GIT_URL+PRAXIS_GIT_REF (default: sibling ../../../../praxis).

set -euo pipefail
cd "$(dirname "$0")"

TRANSPILER_DIR=".."
EXAMPLE_REL="examples/jwt-cel-http.yaml"
OUT_DIR="$PWD/out"
POLICY_DOC="$OUT_DIR/jwt-cel-http-cpex-policy.yaml"
GATEWAY_CONFIG="praxis.yaml"
GATEWAY_LOG="gateway.log"
GATEWAY_PORT=8095
ECHO_PORT=9200
KEYCLOAK_HOST="${KEYCLOAK_HOST:-http://localhost:8081}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-cpex-demo}"
DISCOVERY_URL="${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"

step() { printf "\n\033[1;34m[authpolicy-e2e]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
info() { printf "  %s\n" "$*"; }
die()  { printf "  \033[1;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

ECHO_PID=""
GW_PID=""
cleanup() {
  [ -n "$GW_PID" ]   && kill "$GW_PID"   2>/dev/null || true
  [ -n "$ECHO_PID" ] && kill "$ECHO_PID" 2>/dev/null || true
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

for tool in docker cargo python3 curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# 1. Keycloak (local, self-contained).
step "starting Keycloak (docker compose)"
docker compose up -d keycloak >/dev/null
printf "  waiting for OIDC discovery"
for _ in $(seq 1 90); do
  if curl -sf "$DISCOVERY_URL" >/dev/null 2>&1; then break; fi
  printf "."; sleep 1
done
printf "\n"
curl -sf "$DISCOVERY_URL" >/dev/null 2>&1 || die "Keycloak not ready at $DISCOVERY_URL"
ok "Keycloak realm '$KEYCLOAK_REALM' is up"

# 2. Transpile the AuthPolicy → CPEX policy + Praxis filter block.
step "transpiling $EXAMPLE_REL → $OUT_DIR"
mkdir -p "$OUT_DIR"
( cd "$TRANSPILER_DIR" && cargo run --quiet -- "$EXAMPLE_REL" --out-dir "$OUT_DIR" >/dev/null )
[ -f "$POLICY_DOC" ] || die "expected $POLICY_DOC to be written"
ok "wrote $(basename "$POLICY_DOC") (+ filter block, coverage report)"

# 3. Localhost-dev shim: the transpiler never emits `insecure_http` (a prod
#    JWKS is https). Inject it so CPEX will fetch the http:// Keycloak JWKS.
#    NEVER do this in production — use an https JWKS endpoint instead.
step "patching JWKS decoding_key with insecure_http (localhost dev only)"
if grep -q "insecure_http:" "$POLICY_DOC"; then
  ok "already present"
else
  awk '
    { print }
    /^[[:space:]]+url: http:/ {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "insecure_http: true"
    }
  ' "$POLICY_DOC" > "$POLICY_DOC.tmp" && mv "$POLICY_DOC.tmp" "$POLICY_DOC"
  ok "injected insecure_http: true"
fi

# 4. Build Praxis (host binary, cpex-policy-engine feature).
step "building/resolving the Praxis binary"
GATEWAY_BIN="${GATEWAY_BIN:-$(./build-praxis.sh)}"
[ -x "$GATEWAY_BIN" ] || die "praxis binary not found at '$GATEWAY_BIN'"
ok "$GATEWAY_BIN"

# 5. Echo backend + gateway.
step "starting echo backend on :$ECHO_PORT and gateway on :$GATEWAY_PORT"
if pids=$(lsof -ti ":$GATEWAY_PORT" 2>/dev/null); then kill $pids 2>/dev/null || true; fi
python3 echo-backend.py & ECHO_PID=$!
wait_port 127.0.0.1 "$ECHO_PORT" 10 || die "echo backend did not start"
nohup "$GATEWAY_BIN" -c "$GATEWAY_CONFIG" > "$GATEWAY_LOG" 2>&1 & GW_PID=$!
wait_port 127.0.0.1 "$GATEWAY_PORT" 30 || die "gateway did not start (see $GATEWAY_LOG)"
ok "gateway listening (log: $GATEWAY_LOG)"

# 6. Mint persona tokens (alice=engineer, bob=hr).
step "minting persona tokens"
ALICE="$(./mint-token.sh alice)"
BOB="$(./mint-token.sh bob)"
ok "minted alice (engineer) and bob (hr)"

# 7. Exercise the CEL policy.
GW="http://127.0.0.1:${GATEWAY_PORT}/api/widgets"
fails=0
check() {  # label method token expected
  local label="$1" method="$2" token="$3" expected="$4" code
  if [ -n "$token" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" -H "Authorization: Bearer $token" "$GW")
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$GW")
  fi
  if [ "$code" = "$expected" ]; then
    ok "$label → $code (expected $expected)"
  else
    printf "  \033[1;31m✗ %s → %s (expected %s)\033[0m\n" "$label" "$code" "$expected"
    fails=$((fails + 1))
  fi
}

step "exercising the transpiled CEL policy"
check "GET  + alice (has tool_execute perm) " GET  "$ALICE" 200
check "GET  + bob   (has tool_execute perm) " GET  "$BOB"   200
check "POST + alice (not hr → CEL deny)     " POST "$ALICE" 403
check "POST + bob   (hr → CEL allow)        " POST "$BOB"   200
check "GET  + no token (identity gate)      " GET  ""       401

echo
if [ "$fails" -eq 0 ]; then
  printf "\033[1;32mAll CEL policy checks passed.\033[0m\n"
else
  die "$fails check(s) failed — see $GATEWAY_LOG"
fi
