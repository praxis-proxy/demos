#!/usr/bin/env bash
# Bob (HR manager) calls resources/read for hr://employees/compensation.
# Expected:
#
#   * Gateway returns 200 with the resource's contents array
#   * The resource route's require(role.hr) passes — Bob has role.hr
#   * taint(secret, session) fires — this session is now marked,
#     which scenario 18 uses to prove cross-primitive taint
#   * The MCP server returns full employee compensation data (including
#     SSNs). The route's result: rule (content: redact(!perm.view_ssn))
#     leaves it alone because Bob has perm.view_ssn. Eve gets [REDACTED]
#     (scenario 16)
#
# This is the first demo of a `resource:` route through the policy engine.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → resources/read(hr://employees/compensation)"
note "Expected: 200 OK + contents array with employee compensation data (SSNs included — Bob has perm.view_ssn)"
note "Route: resource:hr://employees/compensation → require(role.hr) → taint(secret, session) → run(audit-log)"
note "Bob has role.hr → policy allows, session is tainted with 'secret'"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

call_resources_read "$BOB" "$CLIENT" "hr://employees/compensation"
