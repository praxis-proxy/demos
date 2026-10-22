#!/usr/bin/env bash
#
# Rebuild the gateway, reset demo containers and volumes, and run smoke tests.
# Stops the gateway on :8090 and waits for Keycloak and Valkey before restarting.
#
# Usage:
#   ./restart.sh
#   REBUILD_IMAGES=1 ./restart.sh  # rebuild container images
#   WITH_SPIRE=1 ./restart.sh      # include workload identity (scenario 13)
#
# Gateway output is written to gateway.log, a symlink into .gwlog/.

set -euo pipefail

cd "$(dirname "$0")"

# GATEWAY_CONFIG selects the IdP and PDP; default is Keycloak + OPA.
# Verify configs also require USE_VERIFY=true so scenarios mint from Verify.
GATEWAY_CONFIG="${GATEWAY_CONFIG:-praxis-opa.yaml}"

# Load Verify credentials for the gateway. See .env.verify.example.
if [ -f .env.verify ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env.verify
  set +a
fi
# WITH_SPIRE=1 enables workload identity and the Keycloak SPIFFE provider.
WITH_SPIRE="${WITH_SPIRE:-0}"
COMPOSE=(docker compose)
if [ "$WITH_SPIRE" = "1" ]; then
  COMPOSE+=(-f docker-compose.yml -f docker-compose.spire.yml)
fi
# Include the attestation profile on teardown. Its services need a join token
# and start after the SPIRE server.
DOWN=("${COMPOSE[@]}")
if [ "$WITH_SPIRE" = "1" ]; then
  DOWN+=(--profile attestation)
fi
# Keep log writes outside the watched config directory. On Linux, writes there
# trigger repeated reloads and discard pending approval state. gateway.log stays
# a symlink for the scenario audit assertions.
GATEWAY_LOG="gateway.log"
GATEWAY_LOG_DIR=".gwlog"
mkdir -p "$GATEWAY_LOG_DIR"
# Replace a previous run's regular file with the symlink (keep real files out
# of the watched dir), but leave an already-correct symlink alone.
if [ ! -L "$GATEWAY_LOG" ]; then
  rm -f "$GATEWAY_LOG"
fi
ln -sfn "$PWD/$GATEWAY_LOG_DIR/$GATEWAY_LOG" "$GATEWAY_LOG"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-http://localhost:8081}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-policy-demo}"
KEYCLOAK_READY_URL="${KEYCLOAK_HOST}/realms/${KEYCLOAK_REALM}/.well-known/openid-configuration"
KEYCLOAK_TIMEOUT="${KEYCLOAK_TIMEOUT:-90}"   # seconds

# Set REBUILD_IMAGES=1 after editing container source.
REBUILD_IMAGES="${REBUILD_IMAGES:-0}"

# Build the gateway unless GATEWAY_BIN is set. GATEWAY_PROFILE=debug builds faster.
GATEWAY_BIN="${GATEWAY_BIN:-$(./build-gateway.sh)}"
if [ ! -x "$GATEWAY_BIN" ]; then
  echo "fatal: gateway binary not found at '$GATEWAY_BIN'." >&2
  echo "  build-gateway.sh builds ./gateway; see gateway/Cargo.toml." >&2
  exit 1
fi

step() { printf "\n\033[1;34m[restart-demo]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m⚠\033[0m %s\n" "$*"; }
die()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; exit 1; }

# Require the exchange secret before starting a Verify configuration.
case "$GATEWAY_CONFIG" in
  *verify*)
    if [ -z "${VERIFY_GATEWAY_CLIENT_SECRET:-}" ]; then
      echo "fatal: $GATEWAY_CONFIG needs VERIFY_GATEWAY_CLIENT_SECRET." >&2
      echo "  cp .env.verify.example .env.verify   # then fill in the secret" >&2
      exit 1
    fi
    # Render the selected policy variant with the current tenant and client ids.
    case "$GATEWAY_CONFIG" in
      *verify-cel*)   VERIFY_VARIANT=cel ;;
      *verify-cedar*) VERIFY_VARIANT=cedar ;;
      *verify-opa*)   VERIFY_VARIANT=opa ;;
      *)
        # Render all variants if the config name does not select one.
        VERIFY_VARIANT="" ;;
    esac
    step "rendering $GATEWAY_CONFIG's policy config from its template"
    # shellcheck disable=SC2086 # intentionally unquoted: empty means "all"
    ./render-verify-config.sh $VERIFY_VARIANT \
      || die "could not render the policy config for $GATEWAY_CONFIG"
    ;;
esac

# 1. Kill any existing gateway on :8090.
step "stopping any existing gateway on :8090"
if pids=$(lsof -ti :8090 2>/dev/null); then
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  # Wait for process exit, not just port release, so old and new gateways
  # do not write concurrently to the same log.
  still_alive() {
    local p
    for p in $pids; do kill -0 "$p" 2>/dev/null && return 0; done
    return 1
  }
  for _ in $(seq 1 15); do
    still_alive || break
    sleep 1
  done
  if still_alive; then
    warn "gateway still running after 15s — kill -9 fallback"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
    for _ in 1 2 3; do still_alive || break; sleep 1; done
  fi
  ok "freed :8090"
else
  ok "no gateway was running"
fi

# 2. docker compose down -v.
step "docker compose down -v (wiping Keycloak + MCP volumes)"
"${DOWN[@]}" down -v --remove-orphans
ok "containers + volumes removed"

# 3. (optional) rebuild container images, then docker compose up -d.
if [ "$REBUILD_IMAGES" = "1" ]; then
  step "docker compose build (REBUILD_IMAGES=1 — rebuilding Keycloak+SPI, auth-channel, hr-mcp)"
  "${DOWN[@]}" build
  ok "images rebuilt"
fi
step "docker compose up -d (fresh start; realm import begins)"
"${COMPOSE[@]}" up -d
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

# Wait for Valkey before the gateway opens its lazy session-store connection.
step "waiting for Valkey (session store)"
deadline=$(( $(date +%s) + 30 ))
while [ "$(docker compose exec -T valkey valkey-cli ping 2>/dev/null | tr -d '\r')" != "PONG" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    die "Valkey not ready after 30s — check 'docker compose logs valkey'"
  fi
  printf "."
  sleep 1
done
printf "\n"
ok "Valkey responding (PONG) on localhost:6379"

# 5. verify-token-exchange smoke check (skip on failure but warn loudly).
step "verifying RFC 8693 token-exchange permission"
if ./verify-token-exchange.sh >/dev/null 2>&1; then
  ok "token exchange permission imported correctly"
else
  warn "verify-token-exchange.sh failed — investigate before running scenarios:"
  ./verify-token-exchange.sh || true
fi

# 5b. (WITH_SPIRE=1) wait for SPIRE's published keys, join the SPIRE agent to
# the server, register the workloads, then register SPIRE as a SPIFFE identity
# provider and create the agent's federated client.
if [ "$WITH_SPIRE" = "1" ]; then
  step "configuring the SPIRE overlay (agent, workloads, SPIFFE IdP, federated client)"
  deadline=$(( $(date +%s) + 60 ))
  while ! curl -fsS http://localhost:8443/keys >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      die "SPIRE keys not published after 60s — check '${COMPOSE[*]} logs spire-oidc'"
    fi
    printf "."
    sleep 2
  done
  printf "\n"
  # Node attestation: the agent trusts only the bundle exported here, and
  # proves itself to the server with a one-time join token. The token's
  # -spiffeID gives the node a stable ID for registration entries to name.
  SPIRE_SERVER=("${COMPOSE[@]}" exec -T spire-server /opt/spire/bin/spire-server)
  "${SPIRE_SERVER[@]}" bundle show > spire/agent/bootstrap.crt
  SPIRE_JOIN_TOKEN=$("${SPIRE_SERVER[@]}" token generate \
    -spiffeID spiffe://policy.demo/node/demo-host | awk '{print $2}')
  [ -n "$SPIRE_JOIN_TOKEN" ] || die "spire-server generated no join token"
  SPIRE_JOIN_TOKEN="$SPIRE_JOIN_TOKEN" "${COMPOSE[@]}" --profile attestation \
    up -d spire-agent workloads >/dev/null 2>&1 \
    || die "SPIRE agent did not start — check '${COMPOSE[*]} --profile attestation logs spire-agent'"
  ./spire/register-workloads.sh >/dev/null
  ./spire/setup-spiffe-idp.sh >/dev/null
  ./spire/configure-federated-client.sh >/dev/null
  ok "SPIRE agent joined, workloads registered, SPIFFE IdP and hr-copilot-agent client configured"
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
