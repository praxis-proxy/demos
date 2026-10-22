#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Read or update an IBM Verify agent lifecycle status.
#
# Usage: ./verify/set-agent-status.sh [ACTIVE|SUSPENDED|UNDER_REVIEW|DEFAULT]
# No argument prints the current status.
#
# Uses the manageAgentStatus operator client from .env.verify and agent ids from
# post_deploy_variables.json. Falls back to the admin client on older setups.
# PUT replaces the full record, so preserve readable fields and re-supply the
# write-only oauthClients association from configuration.
# Requires curl, jq, and python3.
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
# Use the status operator credential; fall back to the admin pair on older setups.
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

# Retry once on transport or 5xx failure, including during status restoration.
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

# Verify readable fields survived replacement. oauthClients is write-only.
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
