#!/usr/bin/env bash
# Eve (HR, no view_ssn perm) reads the compensation resource.
# Expected:
#
#   * Gateway returns 200 with the resource's contents array
#   * The resource route's require(role.hr) passes — Eve has role.hr
#   * The result: rule `content: "str | redact(!perm.view_ssn)"` replaces
#     the WHOLE result.content with [REDACTED] because Eve lacks
#     perm.view_ssn. Resource content is an opaque string (not parsed
#     JSON like tool results), and APL has no substring masking yet, so
#     the whole text goes, not just the SSN. Bob (scenario 15) sees it.
#   * Needs PPE issue 75 (Resource projection) and Praxis building the
#     Resource part from the resources/read response. If SSNs come
#     through unredacted, that has regressed.
#
# This is the resource equivalent of scenario 03 (Eve tool redact), but
# redacts the whole result.content rather than the field result.ssn —
# resource bodies are strings, not objects.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Eve (HR, no view_ssn) → resources/read(hr://employees/compensation)"
note "Expected: 200 OK + contents array"
note "Expected: result.content is '[REDACTED]' (Eve lacks perm.view_ssn; whole content replaced)"

EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

RESPONSE=$(call_resources_read "$EVE" "$CLIENT" "hr://employees/compensation")
echo "$RESPONSE"

# Check if SSNs were redacted
if echo "$RESPONSE" | grep -q 'REDACTED'; then
  echo
  note "Resource response redacted for Eve — result.content redact(!perm.view_ssn) works"
elif echo "$RESPONSE" | grep -qE '[0-9]{3}-[0-9]{2}-[0-9]{4}'; then
  echo
  note "SSN visible in response — result: projection did NOT fire"
  regression "resource result projection"
fi
