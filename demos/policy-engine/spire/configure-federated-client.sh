#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Create (or update) a DEDICATED Keycloak client for the calling agent's
# workload identity, authenticated by its SPIFFE JWT-SVID instead of a secret.
#
# Why a dedicated client and not `hr-copilot`: a Keycloak client has exactly one
# `clientAuthenticatorType`. `hr-copilot` is the app/user-login client (secret,
# used by mint-token.sh for password grants), so it must stay secret-based.
# The workload identity is a separate principal — the agent proving *itself* via
# its SVID — so it gets its own client (`hr-copilot-agent`) whose authenticator
# is `federated-jwt` bound to the SPIFFE ID. This is the standards-track shape
# (draft-ietf-oauth-spiffe-client-auth, profiling RFC 7523 client auth): the
# agent posts its SVID as `client_assertion`
# (type urn:ietf:params:oauth:client-assertion-type:jwt-spiffe); Keycloak
# validates it against the SPIFFE trust bundle (via the `spiffe` IdP, see
# setup-spiffe-idp.sh) and resolves WHICH client from the SVID's `sub`.
#
# The minted base token (azp = this client) is then scoped down to a downstream
# audience by the gateway's standard v2 exchange (leg 2 of the delegator) — the
# agent holds no standing downstream entitlement; the gateway brokers it.
#
# Idempotent: safe to re-run.
set -euo pipefail

KC="${KC:-http://localhost:8081}"
REALM="${REALM:-policy-demo}"
ADMIN="${ADMIN:-admin}"
ADMIN_PW="${ADMIN_PW:-admin}"
IDP_ALIAS="${IDP_ALIAS:-spiffe}"
CLIENT_ID="${CLIENT_ID:-hr-copilot-agent}"
EXPECTED_SUB="${EXPECTED_SUB:-spiffe://policy.demo/agent/hr-copilot}"
# The gateway client that performs the downstream (leg 2) exchange must be
# within this client's token audience, or the exchange fails with
# "Client is not within the token audience". An audience mapper adds it.
EXCHANGE_CLIENT_AUD="${EXCHANGE_CLIENT_AUD:-praxis-gateway}"

echo "-> obtaining admin token"
TOKEN=$(curl -sf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="$ADMIN" -d password="$ADMIN_PW" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

read -r -d '' CLIENT_JSON <<JSON || true
{
  "clientId": "$CLIENT_ID",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "serviceAccountsEnabled": true,
  "standardFlowEnabled": false,
  "directAccessGrantsEnabled": false,
  "clientAuthenticatorType": "federated-jwt",
  "attributes": {
    "jwt.credential.issuer": "$IDP_ALIAS",
    "jwt.credential.sub": "$EXPECTED_SUB"
  },
  "protocolMappers": [
    {
      "name": "praxis-gateway-as-audience",
      "protocol": "openid-connect",
      "protocolMapper": "oidc-audience-mapper",
      "config": {
        "included.client.audience": "$EXCHANGE_CLIENT_AUD",
        "access.token.claim": "true",
        "id.token.claim": "false"
      }
    }
  ]
}
JSON

# Delete any existing client first, then create fresh. Keycloak's client PUT
# does not reliably replace protocolMappers, so recreating is the robust way
# to keep this idempotent AND ensure the audience mapper is present.
CID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$KC/admin/realms/$REALM/clients?clientId=$CLIENT_ID" \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d[0]["id"] if d else "")')
if [ -n "$CID" ]; then
  echo "-> removing existing client '$CLIENT_ID' before recreate"
  curl -sf -X DELETE -H "Authorization: Bearer $TOKEN" "$KC/admin/realms/$REALM/clients/$CID"
fi

echo "-> creating client '$CLIENT_ID' (federated-jwt, sub=$EXPECTED_SUB, aud+=$EXCHANGE_CLIENT_AUD)"
curl -sf -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$KC/admin/realms/$REALM/clients" -d "$CLIENT_JSON"

echo "-> done: '$CLIENT_ID' authenticates by SVID; hr-copilot untouched (still secret)"
