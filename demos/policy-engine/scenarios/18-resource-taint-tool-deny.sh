#!/usr/bin/env bash
# Cross-primitive taint: reading a resource taints the session, then
# a tool call in the same session is denied by the taint label.
#
# Three steps with a shared SESSION_ID:
#   S1: Bob reads hr://employees/compensation (succeeds, taints session)
#   S2: Bob calls send_email in the SAME session (denied — session_tainted_secret)
#   S3: Bob calls send_email with a DIFFERENT session (allowed — clean session)
#
# This proves taint(secret, session) on a resource: route blocks a
# subsequent tool: route in the same session — cross-primitive
# data-flow control.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)
TAINT_SESSION="taint-resource-$$-$RANDOM"
CLEAN_SESSION="clean-resource-$$-$RANDOM"

# ── S1: Read resource (taints session) ───────────────────────────

step "S1 · Bob → resources/read (taints the session)"
note "Session: $TAINT_SESSION"
note "Expected: 200 OK — require(role.hr) ✓, taint(secret, session) fires"

SESSION_ID="$TAINT_SESSION" call_resources_read "$BOB" "$CLIENT" "hr://employees/compensation"

# ── S2: Send email, SAME session (should be denied) ─────────────

step "S2 · Bob → send_email (SAME session as S1, clean body)"
note "Session: $TAINT_SESSION (now carries label \"secret\" from S1)"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=session_tainted_secret"
note "Denied by the SESSION taint — NOT by pii-scan (the body is clean)"
note "This is cross-primitive data-flow control: read resource → can't email out"

SESSION_ID="$TAINT_SESSION" call_send_email "$BOB" "$CLIENT"

# ── S3: Send email, DIFFERENT session (should be allowed) ────────

step "S3 · Bob → send_email (different session, clean body)"
note "Session: $CLEAN_SESSION (never touched secret data)"
note "Expected: 200 OK — different session, no taint"

SESSION_ID="$CLEAN_SESSION" call_send_email "$BOB" "$CLIENT"
