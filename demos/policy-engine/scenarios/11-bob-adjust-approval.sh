#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Bob's >$10k adjustment needs Alice's decision over OIDC CIBA.
#
#   S1 adjust_compensation (+$25k) → -32120 pending; capture the
#      elicitation_id + approver from error.data
#   S2 the manager decides:
#        default        — you open http://localhost:5001 and click Approve
#                          (or Deny)
#        AUTO_APPROVE=1  — the script drives the auth-channel /pending +
#                          /approve endpoints (no human click)
#        AUTO_DENY=1     — same, but POSTs /deny: the manager refuses
#   S3 peek until the gateway reports approval (-32121) or denial.
#      Poll slower than Keycloak's CIBA interval (~5s) to avoid slow_down.
#   S4 re-send without peek. Only an approved adjustment reaches the upstream.
#
# The approval is bound to the amount (scope: args.amount <= 25000), so a
# sign-off can't be replayed against a larger change.
#
# Needs the FULL stack (more than scenarios 01-10): restart.sh brings up
# Keycloak with CIBA + the channel SPI, the auth-channel approval UI on
# :5001, valkey, and the gateway.
# All three PDP configs behave identically (no PDP step here).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

AUTH_CHANNEL="${AUTH_CHANNEL:-http://localhost:5001}"
AMOUNT="${AMOUNT:-25000}"          # > $10k (triggers approval), <= 25000 (scope)
EMPLOYEE="${EMPLOYEE:-EMP-001234}"
APPROVER="${APPROVER:-alice}"       # Bob's manager (claim.manager)
POLL_SECONDS="${POLL_SECONDS:-6}"   # > Keycloak cibaInterval (5s) → no slow_down
MAX_POLLS="${MAX_POLLS:-20}"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

# The auth-channel keeps entries from earlier runs, including abandoned ones
# a manual run left pending. Record them now so S2 can tell this run's request
# apart from those.
PRE_ARIDS=""
if [ -n "${AUTO_APPROVE:-}${AUTO_DENY:-}" ]; then
  PRE_ARIDS=$(curl -fsS "$AUTH_CHANNEL/pending" 2>/dev/null \
                | jq -r '.[].auth_req_id' 2>/dev/null) || true
fi

# --- S1 · the sensitive ask -----------------------------------------------
step "S1 · Bob (HR) → adjust_compensation (+\$$AMOUNT, over the \$10k threshold)"
note "The gateway requested $APPROVER's out-of-band approval and suspended the call"

reset_upstream
RAW=$(_post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
_print_response "$RAW"

expect_status 200
# Suspended, not denied. The distinction is the whole point of the flow.
expect_rpc_error -32120
expect_violation elicitation.pending
expect_upstream_calls 0
BODY=$(_http_body "$RAW")

CODE=$(printf '%s' "$BODY" | jq -r '.error.code // empty' 2>/dev/null || true)
if [ "$CODE" != "-32120" ]; then
  note "Did not get the expected -32120 pending response (got: ${CODE:-none})."
  note "Is the gateway running with the auth-channel (:5001) up?"
  note "See 'Human-in-the-loop: manager approval' in the README."
  exit 1
fi
EID=$(printf '%s' "$BODY" | jq -r '.error.data.elicitation_id // empty' 2>/dev/null || true)
APPROVER=$(printf '%s' "$BODY" | jq -r ".error.data.approver // \"$APPROVER\"" 2>/dev/null || echo "$APPROVER")
note "elicitation_id: $EID"
note "approver: $APPROVER"
[ -n "$EID" ] || { note "No elicitation_id in the response — cannot resume."; exit 1; }

# --- S2 · the manager decides ---------------------------------------------
# AUTO_DENY wins if both flags are set.
if [ -n "${AUTO_DENY:-}" ]; then
  DECISION=deny
elif [ -n "${AUTO_APPROVE:-}" ]; then
  DECISION=approve
else
  DECISION=manual
fi

if [ "$DECISION" != manual ]; then
  if [ "$DECISION" = deny ]; then
    step "S2 · Auto-denying as $APPROVER (AUTO_DENY=1)"
  else
    step "S2 · Auto-approving as $APPROVER (AUTO_APPROVE=1)"
  fi
  note "Driving the auth-channel approval UI programmatically — no human click"
  # The auth-channel keys pending requests by Keycloak's authReqId (not the
  # gateway's elicitation_id), so look it up via the dev-only /pending API.
  # Take the newest id absent from PRE_ARIDS: deciding a leftover would report
  # success while the gateway kept waiting on its own request.
  ARID=""
  for _ in $(seq 1 "$MAX_POLLS"); do
    ARID=$(curl -fsS "$AUTH_CHANNEL/pending?login_hint=$APPROVER" 2>/dev/null \
             | jq -r --arg pre "$PRE_ARIDS" '
                 ($pre | split("\n") | map(select(length > 0))) as $seen
                 | [ .[]
                     | select(.status == "pending")
                     | select(.auth_req_id | IN($seen[]) | not) ]
                 | last.auth_req_id // empty' 2>/dev/null) || true
    [ -n "$ARID" ] && break
    sleep 1
  done
  [ -n "$ARID" ] || { note "No new pending request for $APPROVER at $AUTH_CHANNEL."; exit 1; }
  note "auth_req_id: $ARID → POST /$DECISION"
  curl -fsS -X POST "$AUTH_CHANNEL/$DECISION/$ARID" >/dev/null
  if [ "$DECISION" = deny ]; then
    note "Denied. Keycloak fails the gateway's next CIBA poll (access_denied)."
  else
    note "Approved. Keycloak releases the token on the gateway's next CIBA poll."
  fi
else
  step "S2 · Waiting for $APPROVER to decide"
  note "Open $AUTH_CHANNEL and click Approve (or Deny) on the '$APPROVER' request."
  note "(Or re-run with AUTO_APPROVE=1 / AUTO_DENY=1 to decide automatically.)"
fi

# --- S3 · peek until the approval resolves --------------------------------
step "S3 · Peeking until the gateway reports the approver's decision"
note "Re-sends with X-Policy-Elicitation-Id + peek — reports status, does NOT apply"
OUTCOME=""
for i in $(seq 1 "$MAX_POLLS"); do
  RAW=$(ELICITATION_ID="$EID" ELICITATION_PEEK=1 \
        _post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
  BODY=$(_http_body "$RAW")
  CODE=$(printf '%s' "$BODY" | jq -r '.error.code // empty' 2>/dev/null || true)
  case "$CODE" in
    -32121) OUTCOME=approved; note "poll $i: -32121 approved ✓"; break ;;
    -32120) note "poll $i: -32120 still pending…" ;;
    *)
      _print_response "$RAW"
      if [ "$LAST_STATUS" = 200 ] &&
         printf '%s' "$BODY" | jq -e '.error.message == "elicitation denied by approver"' >/dev/null; then
        OUTCOME=denied
        note "poll $i: approver denied"
        break
      fi
      note "Unexpected response while waiting for Alice's decision."
      exit 1 ;;
  esac
  sleep "$POLL_SECONDS"
done
[ -n "$OUTCOME" ] || { note "No decision observed within ~$((MAX_POLLS * POLL_SECONDS))s."; exit 1; }

if [ "$DECISION" = approve ] && [ "$OUTCOME" != approved ]; then
  note "AUTO_APPROVE=1 but the gateway did not report approved."; exit 1
fi
if [ "$DECISION" = deny ] && [ "$OUTCOME" != denied ]; then
  note "AUTO_DENY=1 but the gateway reported $OUTCOME."; exit 1
fi

# --- S4 · apply (or don't) -------------------------------------------------
if [ "$OUTCOME" = approved ]; then
  step "S4 · Bob re-sends WITHOUT peek to apply the approved change"
  note "The raise lands"
else
  step "S4 · Bob re-sends WITHOUT peek after the denial"
  note "No approval to spend: the raise does not land"
fi
reset_upstream
RAW=$(ELICITATION_ID="$EID" _post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
_print_response "$RAW"

expect_status 200
if [ "$OUTCOME" = approved ]; then
  expect_rpc_ok
  expect_result_field status applied
  # Only now does the tool actually run: the suspended call reached no upstream.
  expect_upstream_calls 1
else
  expect_rpc_error -32120
  expect_violation elicitation.pending
  expect_upstream_calls 0
fi

if [ "$OUTCOME" = approved ]; then
  show_last_audit adjust_compensation
  expect_audit_record adjust_compensation
fi
finish
