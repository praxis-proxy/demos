#!/usr/bin/env bash
#
# Alice passes the team gate but the PDP denies external-repo access.
# Expect HTTP 200 with JSON-RPC -32001 and the selected PDP violation.
# No token exchange or upstream call occurs.

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
