#!/usr/bin/env bash
# Post-phase conditional taint on a resource route.
#
# The resource route has:
#   pre_invocation:  taint(secret, session)                 — unconditional, always fires
#   post_invocation: result != '': taint(pii_resource, session) — conditional on the response
#
# The send_email route checks for both labels, "secret" first:
#   security.labels contains "secret"       → session_tainted_secret
#   security.labels contains "pii_resource" → session_tainted_pii_resource
#
# Two steps with one session:
#   S1: Bob reads the resource. The pre-phase taint adds "secret"; the
#       post-phase taint reads the projected response and adds "pii_resource".
#       The script then reads the session's labels from Valkey and requires
#       pii_resource.
#   S2: Bob sends an email in the same session and is denied.
#
# Why S1 reads Valkey: "secret" is always set and checked first, so S2's deny
# is session_tainted_secret whether or not pii_resource was set. The deny alone
# cannot fail when the post-phase taint breaks; the label in the store can.
#
# Needs PPE issue 75 (Resource projection) and Praxis building the Resource
# part from the resources/read response.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Resource post-phase conditional taint"
note "post_invocation: result != '': taint(pii_resource, session)"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
POST_SESSION="post-res-$$-$RANDOM"

# ── S1: read the resource, then check the session's labels ───────

step "S1 · Bob → resources/read (pre- and post-phase taints fire)"
note "Session: $POST_SESSION"
note "pre_invocation:  taint(secret, session)"
note "post_invocation: result != '': taint(pii_resource, session)"

KEYS_BEFORE=$(taint_keys)
SESSION_ID="$POST_SESSION" call_resources_read "$BOB" "$CLIENT" "hr://employees/compensation"
KEYS_AFTER=$(taint_keys)

# The fresh session id gives exactly one new key: this session's.
NEW_KEYS=$(comm -13 <(echo "$KEYS_BEFORE") <(echo "$KEYS_AFTER"))
if [ "$(echo "$NEW_KEYS" | grep -c .)" -ne 1 ]; then
  echo
  note "ERROR: expected one new session key in Valkey, found: ${NEW_KEYS:-none}"
  exit 1
fi
LABELS=$(valkey smembers "$NEW_KEYS" | sort | paste -sd' ' -)

echo
note "Session labels in Valkey: $LABELS"
if ! echo " $LABELS " | grep -q ' secret '; then
  note "ERROR: no 'secret' label — the pre-phase taint did not fire"
  exit 1
fi
if ! echo " $LABELS " | grep -q ' pii_resource '; then
  note "No 'pii_resource' label — the post-phase taint did not read the response"
  regression "resource post-phase conditional taint"
fi
note "Both labels set — 'pii_resource' came from the resource response"

# ── S2: email in the same session is denied ──────────────────────

step "S2 · Bob → send_email (same session)"
note "Session: $POST_SESSION"
note "Expected: denied by 'session_tainted_secret' ('secret' is checked before 'pii_resource')"

RESPONSE=$(SESSION_ID="$POST_SESSION" call_send_email "$BOB" "$CLIENT")
echo "$RESPONSE"

if echo "$RESPONSE" | grep -qE 'session_tainted_(secret|pii_resource)'; then
  echo
  note "Denied by the session taint, as expected"
else
  echo
  note "ERROR: email not denied by the session taint"
  regression "resource session taint"
fi
