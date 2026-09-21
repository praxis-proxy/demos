#!/usr/bin/env bash
# Eve (HR, no view_ssn perm) calls get_compensation with include_ssn=true.
# This exercises BOTH redaction paths in one shot:
#
#   * args.ssn   — gateway rewrites the REQUEST body before upstream
#                  sees it. Container log shows args.ssn = "[REDACTED]".
#   * result.ssn — gateway rewrites the RESPONSE body before the
#                  client sees it. The client's JSON shows
#                  ssn: "[REDACTED]" even though hr-mcp returned the
#                  actual value (because Eve asked for include_ssn=true).
#
# Eve is HR (role.hr passes the policy gate) so the request goes through.
# She just lacks perm.view_ssn, which is what triggers both redacts.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Eve (HR, no view_ssn) → get_compensation (include_ssn=true)"

EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

reset_upstream
call_get_compensation "$EVE" "$CLIENT" true

expect_status 200
expect_rpc_ok
expect_upstream_calls 1
# Both directions. The tool never receives the SSN, and the client never sees
# it come back, which are two separate rewrites.
expect_upstream_arg ssn "[REDACTED]"
expect_result_field ssn "[REDACTED]"
finish
