#!/usr/bin/env bash
# Prompt result redaction depends on who asks. The same prompts/get for
# summarize-report with include_ssn=true, twice:
#
#   S1: Eve (HR, no view_ssn) → the server puts the SSN in the prompt, and
#       the result: rule `content: "str | redact(!perm.view_ssn)"` replaces
#       the WHOLE result.content with [REDACTED]. Prompt content is a
#       rendered text string, and APL has no substring masking yet, so the
#       whole text goes, not just the SSN.
#   S2: Bob (HR + view_ssn) → same request, same server response; the rule
#       leaves it alone and Bob sees the SSN.
#
# S2 is the control: it proves S1's redaction is the policy deciding on
# perm.view_ssn, not the gateway redacting every prompt.
#
# Needs PPE issue 75 (PromptResult projection) and Praxis building the
# PromptResult part from the prompts/get response, and writing it back.
#
# This is the prompt equivalent of scenario 16 (resource result redact),
# using the same rule on result.content.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

ARGS='{"employee_id":"EMP-001234","include_ssn":true}'
SSN_PATTERN='[0-9]{3}-[0-9]{2}-[0-9]{4}'
CLIENT=$(mint hr-copilot)

# ── S1: Eve — redacted ───────────────────────────────────────────

step "S1 · Eve (HR, no view_ssn) → prompts/get(summarize-report, include_ssn=true)"
note "Expected: 200 OK + messages array"
note "Expected: result.content is '[REDACTED]' (Eve lacks perm.view_ssn; whole content replaced)"

EVE=$(mint eve)
RESPONSE=$(call_prompts_get "$EVE" "$CLIENT" "summarize-report" "$ARGS")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -qE "$SSN_PATTERN"; then
  echo
  note "SSN visible in Eve's response — the result: rule did NOT redact"
  regression "prompt result redaction"
elif echo "$RESPONSE" | grep -q 'REDACTED'; then
  echo
  note "Prompt response redacted for Eve — result.content redact(!perm.view_ssn) works"
else
  echo
  note "ERROR: Eve's response has neither [REDACTED] nor an SSN"
  exit 1
fi

# ── S2: Bob — control, not redacted ──────────────────────────────

step "S2 · Bob (HR + view_ssn) → same request  [control]"
note "Expected: 200 OK + the prompt text with the SSN (Bob has perm.view_ssn)"

BOB=$(mint bob)
RESPONSE=$(call_prompts_get "$BOB" "$CLIENT" "summarize-report" "$ARGS")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -qE "$SSN_PATTERN"; then
  echo
  note "Bob sees the SSN — the redaction in S1 was the policy deciding on perm.view_ssn"
elif echo "$RESPONSE" | grep -q 'REDACTED'; then
  echo
  note "Bob's response is redacted too — the rule is not keyed on perm.view_ssn"
  regression "prompt result redaction is not per-user"
else
  echo
  note "ERROR: Bob's response has neither the SSN nor [REDACTED]"
  exit 1
fi
