#!/usr/bin/env bash
# Alice (engineer, role.engineer) calls get_compensation. Expected:
#
#   * Gateway returns an MCP JSON-RPC error (HTTP 200 + error envelope,
#     code -32001) — per MCP's Tools spec, gateway-side denials are
#     reported via the JSON-RPC error mechanism so MCP clients can
#     correlate the failure to the original request id
#   * No token exchange happened (Keycloak's /token endpoint
#     should NOT receive a token-exchange call for this request)
#   * MCP server NEVER sees the call (request short-circuits at policy)

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Alice (engineer) → get_compensation"
note "Triggered by: require(role.hr) deny BEFORE delegation runs"

ALICE=$(mint alice)
CLIENT=$(mint hr-copilot)

reset_upstream
call_get_compensation "$ALICE" "$CLIENT" false

expect_status 200
expect_rpc_error -32001
expect_violation "routes.tool:get_compensation.pre_invocation[0]"
expect_upstream_calls 0
finish
