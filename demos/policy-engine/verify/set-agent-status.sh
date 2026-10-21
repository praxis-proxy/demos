#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Set an IBM Verify Agent Registry record's lifecycle status.
#
#   ./verify/set-agent-status.sh SUSPENDED      # revoke the agent
#   ./verify/set-agent-status.sh ACTIVE         # restore it
#   ./verify/set-agent-status.sh                # just report the current status
#
# This is the demo's kill switch, and the thing that distinguishes IBM Verify
# Agent Identity from SPIFFE/SPIRE: an admin can disable a specific agent by
# name, in a console, and the next call fails. Scenario 14 drives it; an
# operator can also run it by hand mid-demo.
#
# ---------------------------------------------------------------------------
# Why this is a script and not an inline curl
# ---------------------------------------------------------------------------
# PUT /v1.0/Agents/{id} is a FULL REPLACE. A PUT carrying only `status` clears
# description, tags and — critically — `oauthClients`, which is what binds the
# record to the agent's OAuth client. Unbind that and the agent is no longer
# the agent, which is a far worse outcome than a failed suspend.
#
# Worse, the association cannot be recovered by reading first: `oauthClients`
# is WRITE-ONLY on this tenant and always reads back as null, even immediately
# after a write that accepted it. So a naive read-then-write loses it too.
#
# This script therefore reconstructs the full record on every write: the
# readable fields come from the GET, and the association is re-supplied from
# configuration (the same values verify/import-verify-clients.sh wrote).
#
# Verified against praxis-2. Note also that IBM Verify does NOT enforce status
# at the token endpoint: a SUSPENDED agent still mints tokens, and tokens
# minted before the suspend stay valid. Enforcement is the gateway's job (see
# the agent-status plugin). This script changes the record; it does not by
# itself stop anything.
#
# ---------------------------------------------------------------------------
# Which credential this uses, and why it is not the gateway's
# ---------------------------------------------------------------------------
# This script authenticates with VERIFY_AGENT_OPERATOR_CLIENT_ID/_SECRET, an
# API client holding exactly one entitlement: `manageAgentStatus`. Verified
# against a live tenant, that permits a status change and nothing else — not
# even renaming the agent (403 CSINH2507E), let alone touching users,
# applications or other API clients (403).
#
# It is deliberately a DIFFERENT credential from the gateway's
# VERIFY_AGENT_READER_CLIENT_ID/_SECRET, which holds `readAgents` and cannot
# write at all (403 on PUT /v1.0/Agents). That split is a security boundary: if
# the gateway could also change status, a compromised gateway could re-enable
# the agent its own policy just suspended, and the kill switch would be its own
# bypass.
#
# The tenant-admin pair is NOT used here. It stays provisioning-only.
#
# Requires: curl, jq, python3. Reads .env.verify for the operator credential and
# post_deploy_variables.json for VERIFY_AGENT_ID / AGENT_CLIENT_ID.
set -uo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PDV="${PDV:-$DEMO_DIR/post_deploy_variables.json}"

die()  { printf '\033[1;31merror\033[0m %s\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }

WANT="${1:-}"
case "$WANT" in
  ''|ACTIVE|SUSPENDED|UNDER_REVIEW|DEFAULT) ;;
  -h|--help) sed -n '2,/^set /p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
  *) die "status must be one of ACTIVE | SUSPENDED | UNDER_REVIEW | DEFAULT (got '$WANT')" ;;
esac

[ -f "$DEMO_DIR/.env.verify" ] || die "missing $DEMO_DIR/.env.verify (see .env.verify.example)"
# shellcheck disable=SC1091
set -a; . "$DEMO_DIR/.env.verify"; set +a
# The OPERATOR credential: manageAgentStatus only. Deliberately not the admin
# pair (which stays provisioning-only) and deliberately not the gateway's
# reader credential — see the header.
#
# Falls back to the admin pair only if no operator client is configured, so a
# tenant provisioned before this split still works. The fallback is announced,
# because running an admin credential on the demo path is worth noticing.
OP_ID="${VERIFY_AGENT_OPERATOR_CLIENT_ID:-}"
OP_SECRET="${VERIFY_AGENT_OPERATOR_CLIENT_SECRET:-}"
USING_ADMIN=false
if [ -z "$OP_ID" ] || [ -z "$OP_SECRET" ]; then
  OP_ID="${VERIFY_ADMIN_CLIENT_ID:-}"
  OP_SECRET="${VERIFY_ADMIN_CLIENT_SECRET:-}"
  USING_ADMIN=true
fi
if [ -z "$OP_ID" ] || [ -z "$OP_SECRET" ]; then
  die "no agent-status operator credential in .env.verify.
  Expected VERIFY_AGENT_OPERATOR_CLIENT_ID / _SECRET (manageAgentStatus only).
  Run ./verify/import-verify-clients.sh to create it."
fi
[ -f "$PDV" ] || die "missing $PDV"

pdv() { jq -r --arg k "$1" '.variables[$k] // empty' "$PDV"; }

TENANT_URL="${VERIFY_TENANT_URL:-$(pdv IBM_VERIFY_TOKEN_ENDPOINT | sed 's|/oauth2/token$||')}"
[ -n "$TENANT_URL" ] || die "cannot determine the tenant URL; export VERIFY_TENANT_URL"
AGENT_ID="${VERIFY_AGENT_ID:-$(pdv VERIFY_AGENT_ID)}"
[ -n "$AGENT_ID" ] || die "VERIFY_AGENT_ID is unknown — run ./verify/import-verify-clients.sh first"
AGENT_CLIENT_ID="${AGENT_CLIENT_ID:-$(pdv AGENT_CLIENT_ID)}"

TOKEN=$(curl -sS "$TENANT_URL/oauth2/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "client_id=$OP_ID" \
  --data-urlencode "client_secret=$OP_SECRET" | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || die "could not obtain a token from $TENANT_URL"
if [ "$USING_ADMIN" = true ]; then
  note "warning: falling back to the ADMIN credential — no operator client configured."
  note "  run ./verify/import-verify-clients.sh to create a manageAgentStatus-only one."
fi

get_record() {
  curl -sS "$TENANT_URL/v1.0/Agents/$AGENT_ID" \
    -H "Authorization: Bearer $TOKEN" -H 'Accept: application/scim+json'
}

RECORD="$(get_record)"
CURRENT=$(printf '%s' "$RECORD" | jq -r '.status // empty')
[ -n "$CURRENT" ] || die "no agent record at /v1.0/Agents/$AGENT_ID — check VERIFY_AGENT_ID"

DISPLAY=$(printf '%s' "$RECORD" | jq -r '.displayName // empty')

# Report-only mode.
if [ -z "$WANT" ]; then
  printf '  %s  status=\033[1m%s\033[0m  (id=%s)\n' "$DISPLAY" "$CURRENT" "$AGENT_ID"
  exit 0
fi

if [ "$CURRENT" = "$WANT" ]; then
  note "$DISPLAY is already $WANT — nothing to do"
  exit 0
fi

[ -n "$AGENT_CLIENT_ID" ] || die \
  "AGENT_CLIENT_ID is unknown, so the oauthClients association cannot be re-sent.
  A full-replace PUT without it would unbind the agent from its OAuth client.
  Re-run ./verify/import-verify-clients.sh, or export AGENT_CLIENT_ID."

# Full replace: readable fields from the GET, association re-supplied from
# config because it is never readable. See the header.
BODY=$(printf '%s' "$RECORD" | jq -c \
  --arg status "$WANT" \
  --arg cid "$AGENT_CLIENT_ID" \
  --arg iss "$TENANT_URL/oauth2" '
  {
    schemas: (.schemas // ["urn:ietf:params:scim:schemas:core:ibm:2.0:Agent"]),
    displayName: .displayName,
    status: $status,
    oauthClients: [{ issuer: $iss, clientId: $cid, purposes: ["agent_id", "authentication"] }]
  }
  + (if .description then {description: .description} else {} end)
  + (if (.tags // []) | length > 0 then {tags: .tags} else {} end)
  + (if (.owners // []) | length > 0 then {owners: [.owners[] | {value: .value}]} else {} end)')

# One retry on a transient failure. The tenant occasionally answers 5xx or
# drops the connection, and a scenario that suspends an agent and then cannot
# restore it leaves the next run starting from SUSPENDED — a confusing failure
# that has nothing to do with the code under test.
put_status() {
  curl -sS -o "/tmp/set-agent-status.$$" -w '%{http_code}' --max-time 20 -X PUT \
    "$TENANT_URL/v1.0/Agents/$AGENT_ID" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Accept: application/scim+json' -H 'Content-Type: application/scim+json' \
    --data "$BODY"
}
CODE=$(put_status)
case "$CODE" in
  5*|000)
    note "PUT returned $CODE — retrying once"
    sleep 2
    CODE=$(put_status) ;;
esac

case "$CODE" in
  200|204) ;;
  403) rm -f "/tmp/set-agent-status.$$"
       die "HTTP 403 — this client cannot change agent status.
  The operator client needs 'manageAgentStatus'. If it has it, the payload may
  be altering a non-status field: with that entitlement every other field must
  match what is stored (CSINH2507E)." ;;
  *)   printf '  '; jq -r '.detail // .' "/tmp/set-agent-status.$$" 2>/dev/null || cat "/tmp/set-agent-status.$$"
       rm -f "/tmp/set-agent-status.$$"
       die "PUT /v1.0/Agents/$AGENT_ID returned HTTP $CODE" ;;
esac
rm -f "/tmp/set-agent-status.$$"

AFTER=$(get_record)
NOW=$(printf '%s' "$AFTER" | jq -r '.status // empty')
if [ "$NOW" != "$WANT" ]; then
  die "PUT succeeded but the record reads back status=$NOW, expected $WANT"
fi

# The full-replace hazard this script exists to avoid — assert we did not clear
# the fields we re-sent. oauthClients is deliberately NOT checked: it is
# write-only and always reads back null, so a check here would always fail.
LOST=""
[ "$(printf '%s' "$AFTER" | jq -r '.displayName // empty')" = "$DISPLAY" ] || LOST="displayName"
[ "$(printf '%s' "$RECORD" | jq -r '(.tags // []) | length')" = "$(printf '%s' "$AFTER" | jq -r '(.tags // []) | length')" ] \
  || LOST="${LOST:+$LOST, }tags"
[ -z "$LOST" ] || note "warning: the full-replace PUT appears to have dropped: $LOST"

printf '  %s  \033[1;33m%s\033[0m -> \033[1;32m%s\033[0m\n' "$DISPLAY" "$CURRENT" "$NOW"
if [ "$WANT" != "ACTIVE" ]; then
  note "the agent can still MINT a token — Verify does not gate issuance on status."
  note "the gateway is what refuses the call (violation auth.agent_suspended)."
fi
