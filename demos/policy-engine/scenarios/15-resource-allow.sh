#!/usr/bin/env bash
# Bob (HR manager) calls resources/read for hr://employees/compensation.
# Expected:
#
#   * Gateway returns 200 with the resource's contents array
#   * The resource route's require(role.hr) passes — Bob has role.hr
#   * taint(secret, session) fires — this session is now marked,
#     which scenario 17 will use to prove cross-primitive taint
#   * The MCP server receives the request and returns full employee
#     compensation data (including SSNs — Bob has perm.view_ssn)
#
# This is the first demo of a `resource:` route through the policy engine.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR) → resources/read(hr://employees/compensation)"
note "Expected: 200 OK + contents array with employee compensation data"
note "Route: resource:hr://employees/compensation → require(role.hr) → taint(secret, session) → run(audit-log)"
note "Bob has role.hr → policy allows, session is tainted with 'secret'"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

call_resources_read "$BOB" "$CLIENT" "hr://employees/compensation"
