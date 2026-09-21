#!/usr/bin/env bash
# Alice (engineering, gh_permissions=[repo:read:internal]) calls
# search_repos for an INTERNAL repo. Expected:
#
#   Layer 1 — APL gate `require(group.engineering OR group.security)`
#             → passes (Alice is engineering)
#   Layer 2 — PDP `engineering-internal-repos` rule (Cedar in
#             policy.yaml; the equivalent CEL expr in policy-cel.yaml; the
#             equivalent Rego rule in policy-opa.yaml)
#             → permits (engineer + visibility=internal)
#   Layer 3 — Token exchange to github-api
#             → Keycloak mints token with permissions=[repo:read:internal]
#             (Alice's gh_permissions user attribute → claim mapper)
#   Layer 4 — `delegation.granted.permissions contains 'repo:read:internal'`
#             → passes
#
# Result: 200, hr-mcp logs show Authorization=<minted github token>
#         and the parsed args reach the tool intact.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Alice (engineering) → search_repos(repo_name='web-app', visibility='internal')"

ALICE=$(mint alice)
CLIENT=$(mint hr-copilot)

reset_upstream
call_search_repos "$ALICE" "$CLIENT" internal web-app

expect_status 200
expect_rpc_ok
expect_no_violation
expect_upstream_calls 1
# A different tool, so a different audience: the exchange is per-route.
expect_upstream_audience github-api
finish
