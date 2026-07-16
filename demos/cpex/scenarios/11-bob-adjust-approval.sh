#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Human-in-the-loop manager approval — the over-threshold half.
# Bob asks for a >$10k adjustment; the gateway SUSPENDS the call with
# JSON-RPC -32120 (NOT a deny) and requests Bob's manager (Alice) to
# approve out-of-band over OIDC CIBA. The four beats:
#
#   S1 adjust_compensation (+$25k) → -32120 pending; capture the
#      elicitation_id + approver from error.data
#   S2 the manager approves:
#        default        — you open http://localhost:5001 and click Approve
#        AUTO_APPROVE=1  — the script drives the auth-channel /pending +
#                          /approve endpoints (no human click)
#   S3 peek (X-Policy-Elicitation-Id + peek) until the gateway answers
#      -32121 (approved) — reports status, does NOT apply. Polls slower
#      than Keycloak's CIBA interval (~5s) to avoid a slow_down.
#   S4 re-send WITHOUT peek → 200 OK, status "applied" — the raise lands.
#
# The approval is bound to the amount (scope: args.amount <= 25000), so a
# sign-off can't be replayed against a larger change.
#
# Needs the FULL stack (more than scenarios 01-10): restart.sh brings up
# Keycloak with CIBA + the channel SPI, the auth-channel approval UI on
# :5001, valkey, and the gateway built from the feat/hil_apl praxis fork.
# Both cpex.yaml and cpex-cel.yaml behave identically (no PDP step here).

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

# --- S1 · the sensitive ask -----------------------------------------------
step "S1 · Bob (HR) → adjust_compensation (+\$$AMOUNT, over the \$10k threshold)"
note "Expected: HTTP 200 + JSON-RPC error -32120 (pending) — NOT a deny"
note "The gateway requested $APPROVER's out-of-band approval and suspended the call"

RAW=$(_post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
_print_response "$RAW"
BODY=$(_http_body "$RAW")

CODE=$(printf '%s' "$BODY" | jq -r '.error.code // empty' 2>/dev/null || true)
if [ "$CODE" != "-32120" ]; then
  note "Did not get the expected -32120 pending response (got: ${CODE:-none})."
  note "Is the gateway on the feat/hil_apl fork with the auth-channel (:5001) up?"
  note "See 'Human-in-the-loop: manager approval' in the README."
  exit 1
fi
EID=$(printf '%s' "$BODY" | jq -r '.error.data.elicitation_id // empty' 2>/dev/null || true)
APPROVER=$(printf '%s' "$BODY" | jq -r ".error.data.approver // \"$APPROVER\"" 2>/dev/null || echo "$APPROVER")
note "elicitation_id: $EID"
note "approver: $APPROVER"
[ -n "$EID" ] || { note "No elicitation_id in the response — cannot resume."; exit 1; }

# --- S2 · the manager approves --------------------------------------------
if [ -n "${AUTO_APPROVE:-}" ]; then
  step "S2 · Auto-approving as $APPROVER (AUTO_APPROVE=1)"
  note "Driving the auth-channel approval UI programmatically — no human click"
  # The auth-channel keys pending requests by Keycloak's authReqId (not the
  # gateway's elicitation_id), so look it up via the dev-only /pending API.
  ARID=""
  for _ in $(seq 1 "$MAX_POLLS"); do
    ARID=$(curl -fsS "$AUTH_CHANNEL/pending?login_hint=$APPROVER" 2>/dev/null \
             | jq -r '.[0].auth_req_id // empty' 2>/dev/null) || true
    [ -n "$ARID" ] && break
    sleep 1
  done
  [ -n "$ARID" ] || { note "No pending request for $APPROVER at $AUTH_CHANNEL."; exit 1; }
  note "auth_req_id: $ARID → POST /approve"
  curl -fsS -X POST "$AUTH_CHANNEL/approve/$ARID" >/dev/null
  note "Approved. Keycloak releases the token on the gateway's next CIBA poll."
else
  step "S2 · Waiting for $APPROVER to approve"
  note "Open $AUTH_CHANNEL and click Approve on the '$APPROVER' request."
  note "(Or re-run with AUTO_APPROVE=1 to drive the approval automatically.)"
fi

# --- S3 · peek until approved ---------------------------------------------
step "S3 · Peeking until the gateway reports approved (-32121)"
note "Re-sends with X-Policy-Elicitation-Id + peek — reports status, does NOT apply"
APPROVED=""
for i in $(seq 1 "$MAX_POLLS"); do
  RAW=$(ELICITATION_ID="$EID" ELICITATION_PEEK=1 \
        _post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
  CODE=$(_http_body "$RAW" | jq -r '.error.code // "200"' 2>/dev/null || echo "?")
  case "$CODE" in
    -32121) APPROVED=1; note "poll $i: -32121 approved ✓"; break ;;
    -32120) note "poll $i: -32120 still pending…" ;;
    *)      note "poll $i: resolved with code $CODE"; _print_response "$RAW"; break ;;
  esac
  sleep "$POLL_SECONDS"
done
[ -n "$APPROVED" ] || { note "Approval not observed within ~$((MAX_POLLS * POLL_SECONDS))s."; exit 1; }

# --- S4 · apply ------------------------------------------------------------
step "S4 · Bob re-sends WITHOUT peek to apply the approved change"
note "Expected: HTTP 200 + status \"applied\" — the raise lands"
RAW=$(ELICITATION_ID="$EID" _post_tool "$BOB" "$CLIENT" "$(adjust_compensation_body "$AMOUNT" "$EMPLOYEE")")
_print_response "$RAW"
show_last_audit adjust_compensation
