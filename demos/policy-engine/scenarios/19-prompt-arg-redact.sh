#!/usr/bin/env bash
# Eve (HR, no view_ssn) calls prompts/get with an SSN value in the
# arguments. The args: block should redact it BEFORE the MCP server
# sees the request.
#
# Expected:
#   * Gateway returns 200 with the prompt response
#   * The args.ssn field was rewritten to "[REDACTED]" in the request
#     body before it reached the MCP server
#   * Check MCP server logs to confirm [REDACTED] arrived
#
# This tests request-side (args:) redaction on prompt routes, which
# uses the PromptRequest content part. Scenario 17 covers the response
# side (result:).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Eve (HR, no view_ssn) → prompts/get(summarize-report) with SSN in args"
note "Expected: 200 OK + prompt response"
note "Expected upstream: args.ssn = '[REDACTED]' (gateway rewrote the REQUEST)"
note "The args: redaction on prompt routes uses PromptRequest projection (works)"

EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

call_prompts_get "$EVE" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234","include_ssn":true,"ssn":"999-88-7777"}'

# Check MCP server logs to confirm the SSN was redacted before arrival
echo
note "Checking MCP server logs for what arrived upstream:"
UPSTREAM_ARGS=$(docker compose logs --tail 20 hr-mcp 2>/dev/null | grep 'body.params.arguments' | tail -1)
if echo "$UPSTREAM_ARGS" | grep -q 'REDACTED'; then
  note "✓ Upstream saw args.ssn = '[REDACTED]' — request-side redaction worked"
  echo "  $UPSTREAM_ARGS"
elif echo "$UPSTREAM_ARGS" | grep -q '999-88-7777'; then
  note "✗ Upstream saw the raw SSN — args: redaction did NOT fire"
  echo "  $UPSTREAM_ARGS"
fi
