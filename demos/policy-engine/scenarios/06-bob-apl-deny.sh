#!/usr/bin/env bash
#
# Bob fails require(team.engineering | team.security).
# Expect JSON-RPC -32001 before the PDP, token exchange, or upstream call.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → search_repos (gateway short-circuits at the APL gate)"
note "Triggered by: require(team.engineering | team.security) — Bob is team.hr"
note "The PDP never runs and the IdP is never called"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

reset_upstream
call_search_repos "$BOB" "$CLIENT" internal

expect_status 200
expect_rpc_error -32001
expect_violation "routes.tool:search_repos.pre_invocation[0]"
expect_upstream_calls 0
finish
