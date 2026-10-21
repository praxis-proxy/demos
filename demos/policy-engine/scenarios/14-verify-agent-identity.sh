#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Agent identity: a GOVERNED agent acts as itself, and an admin can switch it off.
#
# Scenario 13 proves an agent can be identified — it presents a SPIFFE JWT-SVID
# that SPIRE issued only because the process passed attestation. That answers
# "is this really the agent?" and nothing else. There is no registry of agents,
# no owner, no status, and no way for a human to say "not that one, not today".
#
# This scenario is the other half, and it is the half enterprises ask about.
# The agent is an IBM Verify Agent Identity: a first-class record in the Agent
# Registry with a display name, an owner, tags, and a lifecycle status. It
# authenticates as itself with client_credentials — no human, no user token —
# and calls search_repos_agent on its own authority. Then an admin suspends it,
# and the next call fails.
#
# What the gateway does:
#
#   1. resolves the agent from X-Agent-Token alone (jwt-agent, role: user, with
#      replace_inherited so the global user/client resolvers do not run),
#   2. runs `run(agent-status)`, which reads the agent's record from
#      /v1.0/Agents and denies unless its status is ACTIVE,
#   3. runs `delegate(github-oauth, ..., subject: user)` to obtain a
#      github-api-scoped credential — the agent holds no standing GitHub
#      entitlement; the gateway brokers one for the call,
#   4. strips a stray X-User-Token and a spoofed X-Auth-User-Id.
#
# ---------------------------------------------------------------------------
# Why the gateway enforces status, and not IBM Verify
# ---------------------------------------------------------------------------
# Verify RECORDS an agent's status but does not gate token issuance on it: a
# SUSPENDED agent still mints tokens, and tokens minted before the suspend stay
# valid. Verified against a live tenant. That is also IBM's own architecture —
# the Agent-Identity-with-Vault cookbook has the token exchange succeed while
# the RESOURCE denies for a missing/invalid agent registration. Praxis is the
# resource here, so the kill switch lives in policy.
#
# The practical consequence, which this scenario shows rather than hides: the
# plugin caches the status, and that interval IS the revocation window. A
# suspended agent keeps working until the entry expires. SPIFFE has the same
# shape of problem with SVID TTL; neither mechanism is instant.
#
# ---------------------------------------------------------------------------
# Verify-only, by construction
# ---------------------------------------------------------------------------
# Agent Registry is an IBM Verify capability with no Keycloak counterpart, just
# as Keycloak's SPIFFE-native client authentication (scenario 13) has no Verify
# counterpart. Neither scenario ports. On the Keycloak path this one reports
# itself skipped (exit 77).
#
# Needs:
#   USE_VERIFY=true                     and a praxis-verify-* gateway config
#   ./verify/import-verify-clients.sh    to have provisioned the agent
#   .env.verify with the two agent-status credentials, each holding exactly one
#     entitlement and neither able to do the other's job:
#       VERIFY_AGENT_READER_CLIENT_ID/_SECRET      readAgents        — the gateway
#       VERIFY_AGENT_OPERATOR_CLIENT_ID/_SECRET    manageAgentStatus — this script
#     The tenant-admin pair is provisioning-only; nothing here reads it.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

PDV="${PDV:-$DEMO_DIR/post_deploy_variables.json}"

# ---------------------------------------------------------------------------
# Skip guards. Each names what to run, because "skipped" with no reason is
# indistinguishable from "quietly broken".
# ---------------------------------------------------------------------------
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

# The scenario suspends a live tenant record. Restore it however we exit, or a
# failed run leaves the next one starting from SUSPENDED and failing for a
# reason that has nothing to do with the code under test.
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
  # Only X-Agent-Token is load-bearing. The other two are deliberate noise: a
  # stray user token and a spoofed asserted header, both of which the route's
  # strip list must remove before hr-mcp sees them.
  local agent_token="$1"
  curl -isS --max-time 25 -X POST "$GATEWAY/mcp" \
    -H 'Content-Type: application/json' \
    -H "X-Agent-Token: $agent_token" \
    -H 'X-User-Token: stray-user-token' \
    -H 'X-Auth-User-Id: bob' \
    --data '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_repos_agent","arguments":{"visibility":"internal"}}}'
}

# The plugin's cache_ttl_seconds is the revocation window, so a status change
# is not visible until it expires. Read it from the running config rather than
# hardcoding, so editing the config cannot silently make this scenario flaky.
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

# Worth showing rather than asserting away: the IdP still issues. Suspension is
# recorded at Verify but not enforced there, which is exactly why the gateway
# has to be the one to refuse.
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
