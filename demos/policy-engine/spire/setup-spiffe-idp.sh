#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Register SPIRE as a native SPIFFE identity provider ("spiffe") in the
# policy-demo realm, so Keycloak can validate JWT-SVIDs presented as client
# assertions (federated-jwt client authentication). The SVID is never a token
# exchange subject_token here, and legacy token exchange is not enabled.
#
# providerId is "spiffe", NOT "oidc": the generic OIDC broker validates an
# exchanged subject token via the IdP's UserInfo endpoint, which SPIRE does not
# serve (the exchange fails with "user info service disabled"). The native
# SPIFFE provider (feature spiffe:v1, Keycloak 26.4+) instead validates the
# SVID's signature against the trust bundle it fetches from `bundleEndpoint` —
# which is just SPIRE's OIDC discovery JWKS at /keys.
#
# Idempotent: safe to re-run. Requires the stack (keycloak + spire) to be up:
#   docker compose -f docker-compose.yml -f docker-compose.spire.yml up -d
#   ./spire/setup-spiffe-idp.sh
set -euo pipefail

KC="${KC:-http://localhost:8081}"
REALM="${REALM:-policy-demo}"
ADMIN="${ADMIN:-admin}"
ADMIN_PW="${ADMIN_PW:-admin}"
IDP_ALIAS="${IDP_ALIAS:-spiffe}"
TRUST_DOMAIN="${TRUST_DOMAIN:-spiffe://policy.demo}"
# The SPIFFE trust bundle (JWKS) AS REACHED FROM THE KEYCLOAK CONTAINER
# (compose DNS), not the host — Keycloak validates the SVID server-side.
BUNDLE_ENDPOINT="${BUNDLE_ENDPOINT:-http://spire-oidc:8443/keys}"

echo "-> obtaining admin token"
TOKEN=$(curl -sf -X POST "$KC/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d username="$ADMIN" -d password="$ADMIN_PW" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

read -r -d '' IDP_JSON <<JSON || true
{
  "alias": "$IDP_ALIAS",
  "displayName": "SPIFFE (SPIRE)",
  "providerId": "spiffe",
  "enabled": true,
  "storeToken": false,
  "trustEmail": true,
  "config": {
    "trustDomain": "$TRUST_DOMAIN",
    "bundleEndpoint": "$BUNDLE_ENDPOINT",
    "validateSignature": "true"
  }
}
JSON

if curl -sf -o /dev/null -H "Authorization: Bearer $TOKEN" \
     "$KC/admin/realms/$REALM/identity-provider/instances/$IDP_ALIAS"; then
  echo "-> updating existing IdP '$IDP_ALIAS'"
  curl -sf -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$KC/admin/realms/$REALM/identity-provider/instances/$IDP_ALIAS" -d "$IDP_JSON"
else
  echo "-> creating IdP '$IDP_ALIAS'"
  curl -sf -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    "$KC/admin/realms/$REALM/identity-provider/instances" -d "$IDP_JSON"
fi

echo "-> done: SPIFFE IdP '$IDP_ALIAS' (trust domain $TRUST_DOMAIN) validates SVIDs against $BUNDLE_ENDPOINT"
