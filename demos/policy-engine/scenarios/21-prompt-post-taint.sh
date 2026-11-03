#!/usr/bin/env bash
# Post-phase conditional taint on a prompt route.
#
# The prompt route has:
#   pre_invocation:  require(role.hr), run(audit-log)  — no taint
#   post_invocation: result != '': taint(pii_prompt, session) — conditional on response
#
# The send_email route checks:
#   security.labels contains "pii_prompt" → session_tainted_pii_prompt
#
# Unlike scenario 20 (resource), the prompt route has NO pre-phase
# taint, so this cleanly isolates the post-phase conditional taint.
# If issue 75 is fixed and result projects correctly, the taint fires
# and the email is denied. Today, result == '' so the taint never
# fires and the email goes through.
#
# This is the clearest test of the issue 75 gap: a session that
# should be tainted by post-phase response inspection, but isn't.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Prompt post-phase conditional taint (issue 75 gap)"
note "post_invocation: result != '': taint(pii_prompt, session)"
note "Since result projects to '' for prompts, this conditional never matches"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
POST_SESSION="post-prompt-$$-$RANDOM"

step "S1 · Bob → prompts/get (post-phase conditional taint should fire)"
note "Session: $POST_SESSION"
note "pre_invocation: require(role.hr) — no taint"
note "post_invocation: result != '': taint(pii_prompt, session) — won't fire (issue 75)"

SESSION_ID="$POST_SESSION" call_prompts_get "$BOB" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234","include_ssn":true}'

step "S2 · Bob → send_email (same session)"
note "Session: $POST_SESSION"
note "Expected: 200 OK — email sent, because post-phase taint never fired"
note "If issue 75 were fixed, expected: denied by 'session_tainted_pii_prompt'"

RESPONSE=$(SESSION_ID="$POST_SESSION" call_send_email "$BOB" "$CLIENT")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -q 'session_tainted_pii_prompt'; then
  echo
  note "Denied by pii_prompt — post-phase conditional taint IS working!"
  note "This means issue 75 response projection has been fixed."
elif echo "$RESPONSE" | grep -q 'status.*sent'; then
  echo
  note "Email sent — post-phase conditional taint did not fire"
  note "result != '' evaluated as '' != '' → false, because result projects to '' (issue 75)"
  known_gap "prompt post-phase conditional taint"
fi
