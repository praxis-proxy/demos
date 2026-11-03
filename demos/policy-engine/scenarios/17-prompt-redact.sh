#!/usr/bin/env bash
# Eve (HR, no view_ssn perm) calls prompts/get for summarize-report
# with include_ssn=true. Expected:
#
#   * Gateway returns 200 with the prompt's messages array
#   * The result: block should redact SSN in the response because
#     Eve lacks perm.view_ssn
#   * If the result: block doesn't work on prompt routes (issue 75),
#     the SSN will come through unredacted — call known_gap
#
# This is the prompt equivalent of scenario 16 (resource result redact).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Eve (HR, no view_ssn) → prompts/get(summarize-report, include_ssn=true)"
note "Expected: 200 OK + messages array"
note "Expected: SSN in response is '[REDACTED]' (Eve lacks perm.view_ssn)"
note "If SSN is visible, this is issue 75 — result: projection on prompt routes"

EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

RESPONSE=$(call_prompts_get "$EVE" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234","include_ssn":true}')
echo "$RESPONSE"

# Check if SSN was redacted
if echo "$RESPONSE" | grep -q 'REDACTED'; then
  echo
  note "SSN redacted in prompt response — result: block works on prompt routes"
elif echo "$RESPONSE" | grep -qE '[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
  echo
  note "SSN visible in response — result: projection did NOT fire"
  known_gap "prompt result projection"
fi
