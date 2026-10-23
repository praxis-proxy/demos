#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Human-in-the-loop manager approval — the over-threshold half.
# Bob asks for a >$10k adjustment; the gateway SUSPENDS the call with
# JSON-RPC -32120 (a suspension, NOT a policy deny) and asks Bob's manager
# (Alice) to decide out-of-band over OIDC CIBA. She can approve — the
# default beats below — or refuse, which AUTO_DENY=1 exercises: the change
# then never applies. The four beats:
#
#   S1 adjust_compensation (+$25k) → -32120 pending; capture the
#      elicitation_id + approver from error.data
#   S2 the manager decides:
#        default        — you open http://localhost:5001 and click Approve
#                          (or Deny)
#        AUTO_APPROVE=1  — the script drives the auth-channel /pending +
#                          /approve endpoints (no human click)
#        AUTO_DENY=1     — same, but POSTs /deny: the manager refuses
#   S3 peek (X-Policy-Elicitation-Id + peek) until the gateway stops
#      answering -32120: -32121 (approved), or a denial error once the
#      approver refused — reports status, does NOT apply. Polls slower
#      than Keycloak's CIBA interval (~5s) to avoid a slow_down.
#   S4 re-send WITHOUT peek. Approved → 200 OK, status "applied": the raise
#      lands. Denied → the gateway refuses it and the raise never lands.
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
# AUTO_DENY wins over AUTO_APPROVE if someone sets both, so a run asking to see
# the refusal never silently grants the raise instead.
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
# OUTCOME: approved (-32121) or denied (any other error once it stops pending).
# A denial surfaces as a plain JSON-RPC error, not a dedicated code, so it is
# the exit from -32120 — rather than a specific code — that marks the verdict.
OUTCOME=""
for i in $(seq 1 "$MAX_POLLS"); do
  RAW=$(ELICITATION_ID="$EID" ELICITATION_PEEK=1 \
        _post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
  CODE=$(_http_body "$RAW" | jq -r '.error.code // "200"' 2>/dev/null || echo "?")
  case "$CODE" in
    -32121) OUTCOME=approved; note "poll $i: -32121 approved ✓"; break ;;
    -32120) note "poll $i: -32120 still pending…" ;;
    *)      OUTCOME=denied
            note "poll $i: resolved with code $CODE — the approver did not approve"
            _print_response "$RAW"
            break ;;
  esac
  sleep "$POLL_SECONDS"
done
[ -n "$OUTCOME" ] || { note "No decision observed within ~$((MAX_POLLS * POLL_SECONDS))s."; exit 1; }

# A run that asked for one decision but observed the other is a failure of the
# flow, not a different-but-valid result — say so rather than asserting on it.
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
  # A denial is terminal for *that* elicitation — it cannot be resumed into an
  # apply. The re-send is treated as a fresh ask, so the gateway suspends again
  # on a NEW elicitation (-32120) and requires another sign-off. Either way the
  # change does not apply and the tool does not run, which is the claim here.
  # Asserting only "not ok" would also pass on a leftover approval applying the
  # raise, so check the gateway did not produce a result.
  expect_rpc_not_ok
  expect_no_result_applied
  expect_upstream_calls 0
fi

show_last_audit adjust_compensation
expect_audit_record adjust_compensation
finish
