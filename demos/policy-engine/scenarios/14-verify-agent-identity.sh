#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Verify agent identity and suspension enforcement.
#
# Authenticate with X-Agent-Token, check registry status, exchange for GitHub
# access, and strip caller-supplied identity headers. Suspend the agent, wait
# for the status cache to expire, assert denial, then restore its status.
# Verify still issues tokens to a suspended agent; the gateway enforces status.
#
# Requires USE_VERIFY=true, a praxis-verify-* config, and an agent provisioned by
# verify/import-verify-clients.sh. .env.verify must contain the readAgents reader
# and manageAgentStatus operator credentials. Skips with exit 77 if unavailable.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

PDV="${PDV:-$DEMO_DIR/post_deploy_variables.json}"

# Skip when the required Verify configuration is unavailable.
if [ "${USE_VERIFY:-}" != "true" ]; then
  note "agent identity is IBM Verify only (no Keycloak counterpart): skipping"
  note "  run USE_VERIFY=true GATEWAY_CONFIG=praxis-verify-opa.yaml ./restart.sh"
  exit 77
fi

if [ ! -f "$PDV" ]; then
  note "no $PDV: skipping"
  exit 77
fi

pdv() { jq -r --arg k "$1" '.variables[$k] // empty' "$PDV"; }

AGENT_CLIENT_ID="${AGENT_CLIENT_ID:-$(pdv AGENT_CLIENT_ID)}"
AGENT_CLIENT_SECRET="${AGENT_CLIENT_SECRET:-$(pdv AGENT_CLIENT_SECRET)}"
VERIFY_AGENT_ID="${VERIFY_AGENT_ID:-$(pdv VERIFY_AGENT_ID)}"
TOKEN_ENDPOINT="$(pdv IBM_VERIFY_TOKEN_ENDPOINT)"

if [ -z "$AGENT_CLIENT_ID" ] || [ -z "$AGENT_CLIENT_SECRET" ]; then
  note "no agent OAuth client in $(basename "$PDV"): skipping"
  note "  run ./verify/import-verify-clients.sh to provision it"
  exit 77
fi
if [ -z "$VERIFY_AGENT_ID" ]; then
  note "no VERIFY_AGENT_ID in $(basename "$PDV"): skipping"
  note "  the Agent Registry is an Early Access capability; if the importer"
  note "  reported it unavailable, this scenario cannot run on this tenant"
  exit 77
fi
if [ -z "$TOKEN_ENDPOINT" ]; then
  note "no IBM_VERIFY_TOKEN_ENDPOINT in $(basename "$PDV"): skipping"
  exit 77
fi

SET_STATUS="$DEMO_DIR/verify/set-agent-status.sh"
if [ ! -x "$SET_STATUS" ]; then
  note "missing $SET_STATUS: skipping"
  exit 77
fi

# Restore status on exit so a failed run does not leave the agent suspended.
restore_active() { "$SET_STATUS" ACTIVE >/dev/null 2>&1 || true; }
trap restore_active EXIT

mint_agent() {
  # The agent authenticates as ITSELF. No user, no password, no human.
  # scope bounds what the exchanged credential may carry downstream.
  curl -sS --max-time 20 "$TOKEN_ENDPOINT" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode "client_id=$AGENT_CLIENT_ID" \
    --data-urlencode "client_secret=$AGENT_CLIENT_SECRET" \
    --data-urlencode "scope=repo:read:internal" \
    | jq -r '.access_token // empty'
}

call_as_agent() {
  # Authenticate with X-Agent-Token; the route must strip the spoofed user headers.
  local agent_token="$1"
  curl -isS --max-time 25 -X POST "$GATEWAY/mcp" \
    -H 'Content-Type: application/json' \
    -H "X-Agent-Token: $agent_token" \
    -H 'X-User-Token: stray-user-token' \
    -H 'X-Auth-User-Id: bob' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_repos_agent","arguments":{"visibility":"internal"}}}'
}

# Wait for the configured status cache TTL before checking suspension.
ttl_seconds() {
  local cfg="$DEMO_DIR/${GATEWAY_CONFIG:-praxis-verify-opa.yaml}"
  local policy ttl
  policy=$(awk '/config_path:/ {print $2; exit}' "$cfg" 2>/dev/null)
  policy="${policy#./}"
  ttl=$(awk '/name: agent-status/,/^  - name:/ { if ($1 == "cache_ttl_seconds:") { print $2; exit } }' \
    "$DEMO_DIR/$policy" 2>/dev/null)
  printf '%s' "${ttl:-5}"
}
TTL="$(ttl_seconds)"

# ===========================================================================
step "The agent is ACTIVE in IBM Verify, and calls a tool as itself"
# ===========================================================================
"$SET_STATUS" ACTIVE >/dev/null 2>&1 || true
note "agent record $VERIFY_AGENT_ID is ACTIVE"

AGENT_TOKEN="$(mint_agent)"
if [ -z "$AGENT_TOKEN" ]; then
  fail_ "the agent could not mint a token from $TOKEN_ENDPOINT"
  finish
fi
pass_ "agent minted its own token (client_credentials — no human involved)"

reset_upstream
_print_response "$(call_as_agent "$AGENT_TOKEN")"

expect_status 200
expect_rpc_ok
expect_no_violation
expect_upstream_calls 1
# The whole delegation story: the tool is handed an IdP-minted token for its
# own audience, obtained from the agent's token. The agent never held one.
expect_upstream_audience github-api
# The caller's own credentials must not survive the gateway.
expect_upstream_no_header x-user-token
expect_upstream_no_header x-auth-user-id
expect_audit_record search_repos_agent

# ===========================================================================
step "An admin suspends the agent in IBM Verify"
# ===========================================================================
"$SET_STATUS" SUSPENDED >/dev/null 2>&1 || {
  fail_ "could not set the agent to SUSPENDED"
  finish
}
pass_ "agent record set to SUSPENDED"

# Confirm Verify still issues tokens after suspension.
SUSPENDED_TOKEN="$(mint_agent)"
if [ -n "$SUSPENDED_TOKEN" ]; then
  pass_ "a SUSPENDED agent STILL mints a token (Verify does not gate issuance)"
else
  note "the tenant refused to mint for a suspended agent — stricter than when"
  note "  this scenario was written; the gateway check below is then redundant"
  SUSPENDED_TOKEN="$AGENT_TOKEN"
fi

note "waiting ${TTL}s for the gateway's status cache to expire (the revocation window)"
sleep "$((TTL + 2))"

# ===========================================================================
step "The gateway refuses the suspended agent"
# ===========================================================================
reset_upstream
_print_response "$(call_as_agent "$SUSPENDED_TOKEN")"

expect_status 200
expect_violation auth.agent_suspended
# The point of the whole scenario: the token is VALID and the call still fails,
# because governance is enforced where the policy decision is made.
expect_upstream_calls 0

# ===========================================================================
step "The admin re-enables the agent, and it works again"
# ===========================================================================
"$SET_STATUS" ACTIVE >/dev/null 2>&1 || {
  fail_ "could not restore the agent to ACTIVE"
  finish
}
pass_ "agent record set back to ACTIVE"
note "waiting ${TTL}s for the cache to expire again"
sleep "$((TTL + 2))"

reset_upstream
_print_response "$(call_as_agent "$(mint_agent)")"

expect_status 200
expect_rpc_ok
expect_no_violation
expect_upstream_calls 1
expect_upstream_audience github-api

finish
