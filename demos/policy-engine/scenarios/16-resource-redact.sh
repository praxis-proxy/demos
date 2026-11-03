#!/usr/bin/env bash
# Eve (HR, no view_ssn perm) reads the compensation resource.
# Expected:
#
#   * Gateway returns 200 with the resource's contents array
#   * The resource route's require(role.hr) passes — Eve has role.hr
#   * The result: block should redact SSN fields because Eve lacks
#     perm.view_ssn: result.ssn = "[REDACTED]"
#   * If the result: block doesn't work on resource routes (issue 75),
#     SSNs will come through unredacted — call known_gap in that case
#
# This is the resource equivalent of scenario 03 (Eve tool redact).

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Eve (HR, no view_ssn) → resources/read(hr://employees/compensation)"
note "Expected: 200 OK + contents array"
note "Expected: SSN fields are '[REDACTED]' (Eve lacks perm.view_ssn)"
note "If SSNs are visible, this is issue 75 — result: projection on resource routes"

EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

RESPONSE=$(call_resources_read "$EVE" "$CLIENT" "hr://employees/compensation")
echo "$RESPONSE"

# Check if SSNs were redacted
if echo "$RESPONSE" | grep -q 'REDACTED'; then
  echo
  note "SSN redacted in resource response — result: block works on resource routes"
elif echo "$RESPONSE" | grep -qE '[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
  echo
  note "SSN visible in response — result: projection did NOT fire"
  known_gap "resource result projection"
fi
