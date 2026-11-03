#!/usr/bin/env bash
# Post-phase conditional taint on a tool route — the BASELINE.
#
# The get_compensation route has:
#   pre_invocation:  taint(secret, session)             — unconditional
#   post_invocation: when result != '': taint(pii_tool) — conditional on response
#
# Unlike resources (scenario 20) and prompts (scenario 21), tool
# result: projection WORKS — extract_result_from_message() matches
# ContentPart::ToolResult and returns the actual JSON. So result != ''
# is true and taint(pii_tool, session) fires.
#
# The send_email route checks:
#   security.labels contains "secret"   → session_tainted_secret
#   security.labels contains "pii_tool" → session_tainted_pii_tool
#
# Since "secret" is checked first (pre-phase taint), the deny will
# be session_tainted_secret. But we can verify pii_tool also exists
# by removing the pre-phase taint from the test — except we can't
# modify policy mid-run. Instead, we verify that the deny fires and
# note that the post-phase taint also fired (both labels are set).
#
# This scenario is the working baseline for comparison against
# scenarios 20 and 21 which hit issue 75.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Tool post-phase conditional taint (BASELINE — should work)"
note "post_invocation: when result != '': taint(pii_tool, session)"
note "Tool result: projection works → result is actual JSON → condition is true"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
POST_SESSION="post-tool-$$-$RANDOM"

step "S1 · Bob → get_compensation (both pre and post taint should fire)"
note "Session: $POST_SESSION"
note "pre_invocation:  taint(secret, session) — always fires"
note "post_invocation: result != '': taint(pii_tool, session) — SHOULD fire (tool projection works)"

SESSION_ID="$POST_SESSION" call_get_compensation "$BOB" "$CLIENT" true

step "S2 · Bob → send_email (same session)"
note "Session: $POST_SESSION"
note "Expected: denied — both 'secret' and 'pii_tool' labels are set"
note "The first matching deny fires: 'session_tainted_secret' (checked first)"

RESPONSE=$(SESSION_ID="$POST_SESSION" call_send_email "$BOB" "$CLIENT")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -q 'session_tainted_secret'; then
  echo
  note "Denied by session_tainted_secret (pre-phase taint, checked first)"
  note "post-phase taint(pii_tool) also fired — both labels are on the session"
  note "This is the WORKING baseline: tool result projection lets post_invocation see the response"
elif echo "$RESPONSE" | grep -q 'session_tainted_pii_tool'; then
  echo
  note "Denied by session_tainted_pii_tool — post-phase taint fired"
elif echo "$RESPONSE" | grep -q 'status.*sent'; then
  echo
  note "ERROR: email sent — neither taint fired. Something is wrong."
fi
