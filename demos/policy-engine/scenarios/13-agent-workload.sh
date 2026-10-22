#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Authenticate get_headcount with a SPIFFE JWT-SVID from uid 1001 in workloads.
# The gateway exchanges it for a workday-api token and strips stray user headers.
# Requires WITH_SPIRE=1 ./restart.sh; otherwise skips with exit 77.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

WORKLOAD_UID="${WORKLOAD_UID:-1001}"
# The SVID's audience must be the realm issuer: Keycloak's SPIFFE client
# authentication rejects an SVID whose sole audience is not the authorization
# server it is presented to.
REALM_ISSUER="${REALM_ISSUER:-http://localhost:8081/realms/policy-demo}"

if ! curl -sf --max-time 3 -o /dev/null http://localhost:8443/keys; then
  note "SPIRE overlay not running (no keys at localhost:8443): skipping"
  note "  run WITH_SPIRE=1 ./restart.sh to include it"
  exit 77
fi

step "Agent (workload) → get_headcount with its SPIFFE JWT-SVID (no user token)"

FETCH_ERR=$(mktemp)
SVID=$("$DEMO_DIR/spire/fetch-svid.sh" "$WORKLOAD_UID" "$REALM_ISSUER" 2>"$FETCH_ERR") || true
if [ -z "$SVID" ]; then
  fail_ "SPIRE issued no SVID to uid $WORKLOAD_UID: $(cat "$FETCH_ERR")"
  note "check the agent: docker compose -f docker-compose.yml -f docker-compose.spire.yml --profile attestation logs spire-agent"
  rm -f "$FETCH_ERR"
  finish
fi
rm -f "$FETCH_ERR"

reset_upstream
RAW=$(curl -isS --max-time 20 -X POST "$GATEWAY/mcp" \
  -H "Content-Type: application/json" \
  -H "X-Workload-Token: $SVID" \
  -H "X-User-Token: stray" \
  -H "X-Auth-User-Id: bob" \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_headcount","arguments":{}}}')
_print_response "$RAW"

expect_status 200
expect_rpc_ok
expect_no_violation
expect_upstream_calls 1
# The tool is handed a token Keycloak minted for its own audience, obtained
# from the agent's SVID; the agent never held one.
expect_upstream_audience workday-api
# A stray user token and a spoofed asserted header ride along on the request;
# the route's strip list must remove both before hr-mcp sees them.
expect_upstream_no_header x-user-token
expect_upstream_no_header x-auth-user-id

step "An unregistered process in the same container gets no SVID"
# uid 1004 has no registration entry and cannot obtain an SVID.
if SVID_WAIT=0 "$DEMO_DIR/spire/fetch-svid.sh" 1004 "$REALM_ISSUER" >/dev/null 2>&1; then
  fail_ "SPIRE issued an SVID to unregistered uid 1004"
else
  pass_ "SPIRE refused uid 1004 (no identity issued)"
fi
finish