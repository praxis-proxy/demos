#!/usr/bin/env bash
#
# Alice may read an internal repo: team gate and PDP allow, then delegation
# returns a GitHub token with repo:read:internal. Expect HTTP 200 and one upstream call.

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
