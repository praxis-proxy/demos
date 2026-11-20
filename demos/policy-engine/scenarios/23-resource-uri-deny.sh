#!/usr/bin/env bash
# Pre-fetch field rule on a resource route: deny on args.uri.
#
# The hr://employees/directory route has:
#   pre_invocation:
#     require(role.hr)                                        — reads identity
#     args.uri == 'hr://employees/directory': deny(...,
#                                   'resource_uri_blocked')   — reads the request
#
# Two steps:
#   S1 (control): Alice (engineer) reads the directory. Denied by
#       require(role.hr) at pre_invocation[0]. Proves the route matched
#       and its pre-fetch handler ran — so S2's outcome is not "the route
#       never fired".
#   S2: Bob (HR) reads the directory. require(role.hr) passes, so the
#       args.uri rule is next. Expected: denied with resource_uri_blocked.
#
# The host puts a ResourceRef carrying the URI on the request, and PPE
# projects it as args (issue 75), so a rule can read the URI as a value,
# not only select on it through the route.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

URI="hr://employees/directory"
CLIENT=$(mint hr-copilot)

# ── S1: control — route matches, identity gate fires ─────────────

step "S1 · Alice (engineer) → resources/read($URI)  [control]"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=routes.resource:$URI.pre_invocation[0]"
note "Proves the route matched and its pre-fetch rules run"

ALICE=$(mint alice)
CONTROL=$(call_resources_read "$ALICE" "$CLIENT" "$URI")
echo "$CONTROL"

if ! echo "$CONTROL" | grep -q 'pre_invocation\[0\]'; then
  echo
  note "ERROR: control did not deny at pre_invocation[0] — the route did not run as expected"
  exit 1
fi

# ── S2: args.uri deny ────────────────────────────────────────────

step "S2 · Bob (HR) → resources/read($URI)"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=resource_uri_blocked"
note "Rule: args.uri == '$URI': deny(..., 'resource_uri_blocked')"

BOB=$(mint bob)
RESPONSE=$(call_resources_read "$BOB" "$CLIENT" "$URI")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -q 'resource_uri_blocked'; then
  echo
  note "Denied by resource_uri_blocked — args.uri is projected on resource pre-fetch"
elif echo "$RESPONSE" | grep -q '"contents"'; then
  echo
  note "Directory returned — the args.uri rule did not match"
  regression "resource pre-fetch args.uri projection"
else
  echo
  note "ERROR: unexpected response — neither the URI deny nor the resource body"
  exit 1
fi
