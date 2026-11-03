#!/usr/bin/env bash
# Alice (engineer) calls prompts/get for summarize-report. Expected:
#
#   * Gateway returns an MCP JSON-RPC error (HTTP 200 + error envelope,
#     code -32001) — the same deny shape as tool calls
#   * The prompt route's require(role.hr) blocks Alice (she has
#     role.engineer, not role.hr)
#   * MCP server NEVER sees the request — gateway short-circuits

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Alice (engineer) → prompts/get(summarize-report)"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=routes.prompt:summarize-report.pre_invocation[0]"
note "Triggered by: require(role.hr) deny — Alice is an engineer, not HR"
note "Expected upstream: no inbound request (gateway short-circuited)"

ALICE=$(mint alice)
CLIENT=$(mint hr-copilot)

call_prompts_get "$ALICE" "$CLIENT" "summarize-report" '{"employee_id":"EMP-001234"}'
