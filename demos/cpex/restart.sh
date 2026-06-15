#!/usr/bin/env bash
# One-shot restart for the CPEX-Praxis demo. Useful when:
#   * Keycloak / MCP backend volumes need a clean slate (realm-export
#     changes, token-lifespan edits, drifted state mid-demo).
#   * The gateway's cached JWKS goes stale after a Keycloak restart
#     and validation fails with "InvalidSignature".
#   * You want a known-good state before walking through scenarios.
#
# What it does, in order:
#   1. Kill any local praxis-cpex gateway listening on :8090.
#   2. docker compose down -v   (wipe Keycloak/MCP volumes).
#   3. docker compose up -d     (fresh containers, realm re-imported).
#   4. Wait for Keycloak's OIDC discovery to respond.
#   5. Run verify-token-exchange.sh as a smoke check.
#   6. Start the gateway in the background; tee its log into
#      ./gateway.log; wait until :8090 is listening.
#   7. Run scenarios/01-bob-allow.sh as an end-to-end smoke check.
#
# Usage (from this directory):
#   ./restart.sh
#
# Logs:
#   ./gateway.log   — gateway stdout/stderr, follow with `tail -F`.

set -euo pipefail

cd "$(dirname "$0")"

# Praxis binary path — built from the workspace root with
# `cargo build --release --features cpex -p praxis`.
GATEWAY_BIN="../../target/release/praxis"
GATEWAY_CONFIG="praxis.yaml"
GATEWAY_LOG="gateway.log"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-http://localhost:8081}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-cpex-demo}"
KEYCLOAK_READY_URL="${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
KEYCLOAK_TIMEOUT="${KEYCLOAK_TIMEOUT:-90}"   # seconds

if [ ! -x "$GATEWAY_BIN" ]; then
  echo "fatal: $GATEWAY_BIN not found. Build praxis with the cpex feature first:" >&2
  echo "  ( cd ../../ && cargo build --release --features cpex -p praxis )" >&2
  exit 1
fi

step() { printf "\n\033[1;34m[restart-demo]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m⚠\033[0m %s\n" "$*"; }
die()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; exit 1; }

# 1. Kill any existing gateway on :8090.
step "stopping any existing gateway on :8090"
if pids=$(lsof -ti :8090 2>/dev/null); then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  # Wait up to 5s for the port to free.
  for _ in 1 2 3 4 5; do
    lsof -i :8090 >/dev/null 2>&1 || break
    sleep 1
  done
  if lsof -i :8090 >/dev/null 2>&1; then
    warn "port :8090 still bound — kill -9 fallback"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    sleep 1
  fi
  ok "freed :8090"
else
  ok "no gateway was running"
fi

# 2. docker compose down -v.
step "docker compose down -v (wiping Keycloak + MCP volumes)"
docker compose down -v
ok "containers + volumes removed"

# 3. docker compose up -d.
step "docker compose up -d (fresh start; realm import begins)"
docker compose up -d
ok "containers starting"

# 4. Wait for Keycloak's OIDC discovery endpoint.
step "waiting for Keycloak realm import (timeout ${KEYCLOAK_TIMEOUT}s)"
deadline=$(( $(date +%s) + KEYCLOAK_TIMEOUT ))
while ! curl -fsS "$KEYCLOAK_READY_URL" >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "Keycloak not ready after ${KEYCLOAK_TIMEOUT}s — check 'docker compose logs keycloak'"
  fi
  printf "."
  sleep 2
done
printf "\n"
ok "Keycloak responding at $KEYCLOAK_READY_URL"

# 5. verify-token-exchange smoke check (skip on failure but warn loudly).
step "verifying RFC 8693 token-exchange permission"
if ./verify-token-exchange.sh >/dev/null 2>&1; then
  ok "token exchange permission imported correctly"
else
  warn "verify-token-exchange.sh failed — investigate before running scenarios:"
  ./verify-token-exchange.sh || true
fi

# 6. Start the gateway, tee its output to ./gateway.log, wait for :8090.
step "starting gateway (log → $GATEWAY_LOG)"
nohup "$GATEWAY_BIN" -c "$GATEWAY_CONFIG" >"$GATEWAY_LOG" 2>&1 &
GATEWAY_PID=$!
disown
# Poll the port for up to 15s.
for _ in $(seq 1 15); do
  if lsof -i :8090 >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
    die "gateway exited early — see $GATEWAY_LOG"
  fi
  sleep 1
done
if ! lsof -i :8090 >/dev/null 2>&1; then
  die "gateway didn't bind :8090 within 15s — see $GATEWAY_LOG"
fi
ok "gateway up (pid $GATEWAY_PID, log: $GATEWAY_LOG)"

# 7. End-to-end scenario smoke test.
step "smoke test: scenarios/01-bob-allow.sh"
if out=$(./scenarios/01-bob-allow.sh 2>&1); then
  if echo "$out" | grep -q "HTTP/1.1 200 OK"; then
    ok "Bob's get_compensation returned 200 OK"
  else
    warn "scenario ran but didn't return 200 — output:"
    echo "$out" | tail -10 | sed 's/^/    /'
  fi
else
  warn "scenario script failed — output:"
  echo "$out" | tail -10 | sed 's/^/    /'
fi

step "demo ready"
echo "  gateway log:     tail -F $GATEWAY_LOG"
echo "  chat:            cd agent && python chat.py --persona bob"
echo "  watch backend:   docker compose logs -f hr-mcp"
echo "  stop gateway:    pkill -f 'praxis.*praxis.yaml'"
