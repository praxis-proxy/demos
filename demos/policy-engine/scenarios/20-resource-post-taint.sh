#!/usr/bin/env bash
# Post-phase conditional taint on a resource route.
#
# The resource route has:
#   pre_invocation:  taint(secret, session)           — unconditional, always fires
#   post_invocation: result != '': taint(pii_resource, session) — conditional on response
#
# The send_email route checks for both labels:
#   security.labels contains "secret"       → session_tainted_secret
#   security.labels contains "pii_resource" → session_tainted_pii_resource
#
# This scenario uses a FRESH session (not tainted by pre-phase), so
# we can isolate the post-phase taint. But wait — the pre-phase
# taint(secret, session) is unconditional, so it always fires.
# To isolate the post-phase taint, we use a two-step approach:
#
#   S1: Bob reads resource in session A → pre-phase taint fires (secret),
#       post-phase conditional taint should also fire (pii_resource) but
#       won't because result == '' (issue 75)
#   S2: Bob sends email in session A → denied by "secret" (pre-phase),
#       but NOT by "pii_resource" (post-phase never fired)
#   S3: Check the violation code — if "session_tainted_secret" rather than
#       "session_tainted_pii_resource", the post-phase taint didn't fire
#
# When issue 75 is fixed, S2 should show BOTH labels, and the first
# matching deny fires. Since "secret" is checked first, the violation
# will still be "session_tainted_secret". To definitively prove post-phase
# taint, we would need a route without pre-phase taint. This scenario
# documents that the conditional post-phase taint cannot fire today.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Resource post-phase conditional taint (issue 75 gap)"
note "post_invocation: result != '': taint(pii_resource, session)"
note "Since result projects to '' for resources, this conditional never matches"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
POST_SESSION="post-res-$$-$RANDOM"

step "S1 · Bob → resources/read (both pre and post taint should fire)"
note "Session: $POST_SESSION"
note "pre_invocation:  taint(secret, session) — always fires"
note "post_invocation: result != '': taint(pii_resource, session) — won't fire (issue 75)"

SESSION_ID="$POST_SESSION" call_resources_read "$BOB" "$CLIENT" "hr://employees/compensation"

step "S2 · Bob → send_email (same session)"
note "Session: $POST_SESSION"
note "Expected: denied by 'session_tainted_secret' (pre-phase taint)"
note "If post-phase also fired, 'session_tainted_pii_resource' label would also exist"

RESPONSE=$(SESSION_ID="$POST_SESSION" call_send_email "$BOB" "$CLIENT")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -q 'session_tainted_pii_resource'; then
  echo
  note "Denied by pii_resource — post-phase conditional taint IS working!"
  note "This means issue 75 response projection has been fixed."
elif echo "$RESPONSE" | grep -q 'session_tainted_secret'; then
  echo
  note "Denied by secret (pre-phase only) — post-phase conditional taint did NOT fire"
  note "result != '' evaluated as '' != '' → false, because result projects to '' (issue 75)"
  known_gap "resource post-phase conditional taint"
elif echo "$RESPONSE" | grep -q 'status.*sent'; then
  echo
  note "ERROR: email sent — neither taint fired. Something is wrong."
fi
