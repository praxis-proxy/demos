#!/usr/bin/env bash
# Alice (engineering) asks for an EXTERNAL repo. APL's coarse gate
# passes (she IS in engineering), but the PDP policy doesn't permit
# engineering on external visibility — only security can read those.
# The denial happens at the gateway BEFORE any IdP call.
#
#   Layer 1 — APL gate → passes (team.engineering)
#   Layer 2 — PDP → DENIES (engineering rule fails:
#             visibility == "external", not "internal")
#   Layers 3-4 — never reached. No token exchange. GitHub never sees
#             the request.
#
# Result: HTTP 200 + JSON-RPC error code -32001 — per MCP's Tools
# spec, gateway denials are reported as JSON-RPC errors inside HTTP
# 200, not as HTTP 4xx. The data.violation depends on the PDP backend:
# "cedar.default_deny" under policy.yaml (Cedar); "cel.policy_denied"
# under policy-cel.yaml (CEL); "opa.policy_denied" under policy-opa.yaml
# (Rego).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Alice (engineering) → search_repos(visibility='external')"
note "Triggered by: PDP denies — engineering can't read external repos"

ALICE=$(mint alice)
CLIENT=$(mint hr-copilot)

reset_upstream
call_search_repos "$ALICE" "$CLIENT" external partner-sdk

expect_status 200
expect_rpc_error -32001
# The three PDP configs express the same decision, so the scenario asserts
# whichever one is running rather than hard-coding Cedar.
expect_violation "${PDP_DENY_VIOLATION:-cedar.default_deny}"
expect_upstream_calls 0
finish
