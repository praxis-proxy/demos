#!/usr/bin/env bash
# Bob (HR manager, perm.view_ssn) calls get_compensation. Expected:
#
#   * Gateway returns 200 with the tool's response
#   * The HR MCP server logs show:
#       - Authorization: Bearer <minted workday-api-scoped token>
#         (NOT bob's user JWT)
#       - args.ssn arrived intact (Bob has perm.view_ssn → no redact)
#
# Watch the MCP server with:
#   docker compose logs -f hr-mcp

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → get_compensation (include_ssn=true)"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

reset_upstream
call_get_compensation "$BOB" "$CLIENT" true

expect_status 200
expect_rpc_ok
expect_no_violation
expect_upstream_calls 1
# The delegation story: the tool is handed an IdP-minted token for its own
# audience, never Bob's.
expect_upstream_audience workday-api
expect_upstream_no_header x-user-token
# Bob has perm.view_ssn, so nothing redacts on the way in.
expect_upstream_arg ssn "would-be-removed-if-redact-fires"
finish
