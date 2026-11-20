#!/usr/bin/env bash
# Post-phase conditional taint on a prompt route.
#
# The prompt route has:
#   pre_invocation:  require(role.hr), run(audit-log)           — no taint
#   post_invocation: result != '': taint(pii_prompt, session)   — conditional on the response
#
# The send_email route checks:
#   security.labels contains "pii_prompt" → session_tainted_pii_prompt
#
# Unlike scenario 20 (resource), the prompt route has NO pre-phase taint, so
# this isolates the post-phase taint: the email is denied only if the
# post-phase rule read the prompt response.
#
# Needs PPE issue 75 (PromptResult projection) and Praxis building the
# PromptResult part from the prompts/get response.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Prompt post-phase conditional taint"
note "post_invocation: result != '': taint(pii_prompt, session)"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
POST_SESSION="post-prompt-$$-$RANDOM"

step "S1 · Bob → prompts/get (post-phase conditional taint fires)"
note "Session: $POST_SESSION"
note "pre_invocation: require(role.hr) — no taint"
note "post_invocation: result != '': taint(pii_prompt, session)"

SESSION_ID="$POST_SESSION" call_prompts_get "$BOB" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234","include_ssn":true}'

step "S2 · Bob → send_email (same session)"
note "Session: $POST_SESSION"
note "Expected: denied by 'session_tainted_pii_prompt'"

RESPONSE=$(SESSION_ID="$POST_SESSION" call_send_email "$BOB" "$CLIENT")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -q 'session_tainted_pii_prompt'; then
  echo
  note "Denied by pii_prompt — the post-phase taint read the prompt response"
elif echo "$RESPONSE" | grep -q 'status.*sent'; then
  echo
  note "Email sent — the post-phase taint did not fire"
  regression "prompt post-phase conditional taint"
else
  echo
  note "ERROR: unexpected response — neither the pii_prompt deny nor a sent email"
  exit 1
fi
