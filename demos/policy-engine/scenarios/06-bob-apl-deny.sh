#!/usr/bin/env bash
# Bob (HR, group=hr) tries to search github repos. APL's coarse
# gate fails immediately — Bob isn't in engineering or security.
# The deny happens BEFORE Cedar runs, before any IdP call.
#
# This shows the "fast path" in the policy: cheap predicates run
# first, expensive PDP / IdP work only happens for requests that
# clear them.
#
#   Layer 1 — APL gate `require(team.engineering | team.security)`
#             → FAILS (Bob is in team.hr)
#   Layers 2-4 — never reached. Cedar never invoked, IdP never
#             called, no token-exchange round-trip.
#
# Result: HTTP 200 + JSON-RPC error code -32001, data.violation =
# the apl.policy step index that failed.

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
