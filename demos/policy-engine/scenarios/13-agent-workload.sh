#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Workload identity: the AGENT acts as itself, with no human user involved.
# The agent presents only its SPIFFE JWT-SVID (X-Workload-Token) to
# get_headcount, a route that authenticates by the SVID alone (route-level
# `authentication: replace_inherited`). The gateway:
#
#   1. resolves caller_workload from the SVID alone; no user or client token
#      is needed,
#   2. runs `delegate(..., subject: caller_workload)`: leg 1 presents the SVID
#      as an RFC 7523 client assertion (type ...:jwt-spiffe) to authenticate as
#      the hr-copilot-agent client, and leg 2 exchanges that token for a
#      workday-api-scoped credential,
#   3. attaches the minted workday-api token to the upstream call, and strips
#      a stray X-User-Token and a spoofed X-Auth-User-Id the call also carries.
#
# Scenarios 01-12 carry a person's X-User-Token and the client's Authorization;
# this one carries neither. The agent's own workload identity is the whole story.
#
# Needs the SPIRE overlay, which `WITH_SPIRE=1 ./restart.sh` brings up and
# configures. Without it this scenario reports itself skipped (exit 77).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

SPIFFE_ID="${SPIFFE_ID:-spiffe://policy.demo/agent/hr-copilot}"
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

SVID=$( (cd "$DEMO_DIR" && docker compose -f docker-compose.yml -f docker-compose.spire.yml \
          exec -T spire-server /opt/spire/bin/spire-server jwt mint \
          -spiffeID "$SPIFFE_ID" -audience "$REALM_ISSUER") 2>/dev/null | tr -d '[:space:]')
if [ -z "$SVID" ]; then
  fail_ "could not mint an SVID from spire-server"
  finish
fi

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
finish
