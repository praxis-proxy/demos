#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# End-to-end proof of the workload-identity delegation the demo adds: a
# workload's JWT-SVID becomes a downstream-scoped access token, no secrets.
#
# The chain (UC2 — agent acts as ITSELF via its workload identity):
#   1. SPIRE mints the agent's JWT-SVID (aud = the realm issuer, per
#      draft-ietf-oauth-spiffe-client-auth).
#   2. The SVID is presented as an RFC 7523 client_assertion
#      (type ...:jwt-spiffe) — Keycloak validates it against the SPIFFE
#      trust bundle and issues hr-copilot-agent's token. No client secret.
#   3. A standard (v2) token exchange scopes that token down to the
#      workday-api audience with read_compensation. Both tokens are
#      Keycloak-issued (internal->internal), so this is ordinary v2 exchange.
#
# The minted workday-api token keeps sub=service-account-hr-copilot-agent, so the
# workload identity flows through to the downstream call.
#
# Prereq: stack up + IdP/client configured:
#   WITH_SPIRE=1 ./restart.sh
#   ./spire/setup-spiffe-idp.sh && ./spire/configure-federated-client.sh
set -euo pipefail

KC="${KC:-http://localhost:8081}"
REALM="${REALM:-policy-demo}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://policy.demo/agent/hr-copilot}"
AUDIENCE="${AUDIENCE:-workday-api}"
SCOPE="${SCOPE:-read_compensation}"
# The gateway client that performs the downstream exchange (STE-enabled).
EXCHANGE_CLIENT="${EXCHANGE_CLIENT:-praxis-gateway}"
EXCHANGE_SECRET="${EXCHANGE_SECRET:-praxis-gateway-secret}"
TOKEN_URL="$KC/realms/$REALM/protocol/openid-connect/token"
ISSUER="$KC/realms/$REALM"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.spire.yml)

claims() { # decode a JWT payload and print selected claims
  python3 -c '
import sys,json,base64
tok=sys.stdin.read().strip()
p=tok.split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
print("   " + " | ".join(f"{k}={c.get(k)}" for k in sys.argv[1:] if k in c))' "$@"
}

echo "1. SPIRE mints the agent SVID (aud=$ISSUER)"
SVID=$("${COMPOSE[@]}" exec -T spire-server /opt/spire/bin/spire-server jwt mint \
  -spiffeID "$SPIFFE_ID" -audience "$ISSUER" 2>/dev/null | tr -d '[:space:]')
if [ -z "$SVID" ]; then
  echo "   FAIL: spire-server minted no SVID (is the SPIRE overlay up?)" >&2
  exit 1
fi
printf '%s' "$SVID" | claims sub aud iss

echo "2. SVID as client_assertion -> Keycloak issues the workload's token"
HRC=$(curl -sf -X POST "$TOKEN_URL" \
  -d grant_type=client_credentials \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
  -d client_assertion="$SVID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
printf '%s' "$HRC" | claims azp preferred_username aud

echo "3. Standard v2 exchange -> $AUDIENCE token scoped to $SCOPE"
WDAY=$(curl -sf -X POST "$TOKEN_URL" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d client_id="$EXCHANGE_CLIENT" -d client_secret="$EXCHANGE_SECRET" \
  -d subject_token="$HRC" \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d audience="$AUDIENCE" -d scope="$SCOPE" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
printf '%s' "$WDAY" | claims aud scope azp preferred_username

echo "OK: workload SVID -> $AUDIENCE token (scope=$SCOPE), identity preserved."
