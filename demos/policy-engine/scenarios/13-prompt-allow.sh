#!/usr/bin/env bash
# Bob (HR manager) calls prompts/get for summarize-report. Expected:
#
#   * Gateway returns 200 with the prompt's messages array
#   * The prompt route's require(role.hr) passes — Bob has role.hr
#   * The MCP server receives the request and returns the employee
#     compensation report template
#   * The route's result: rule (content: redact(!perm.view_ssn)) leaves
#     the text alone: Bob has perm.view_ssn. Eve gets [REDACTED]
#     (scenario 17)
#
# This is the first demo of a `prompt:` route through the policy engine.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → prompts/get(summarize-report)"
note "Expected: 200 OK + messages array"
note "Route: prompt:summarize-report → require(role.hr) → run(audit-log)"
note "Bob has role.hr → policy allows, MCP server returns prompt template"
note "Bob has perm.view_ssn → result: redact(!perm.view_ssn) leaves the text as sent"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

call_prompts_get "$BOB" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234"}'
