#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Session tainting — cross-tool, cross-request data-flow control.
# get_compensation runs `taint(secret, session)`; a later send_email in
# the SAME session is denied even with a CLEAN body, because the
# *session* (not the content) is tainted. This is what distinguishes it
# from scenario 07's content-based PII deny.
#
# Three beats, with fresh per-run session ids so reruns start clean
# (taint labels persist in the Valkey session store, keyed by
# H(subject:session_id), so a fixed id would carry over between runs):
#   S1 send_email (clean session)      → 200 OK
#   S2 get_compensation (taints sess)  → 200 OK  (+ taint(secret, session))
#   S3 send_email (SAME session as S2) → HTTP 200 + JSON-RPC error -32001,
#      violation = session_tainted_secret   (clean body, tainted session)
#
# The session id is threaded via the X-Session-Id header (see _lib.sh);
# the praxis cpex filter maps it to agent.session_id and the cpex
# session store binds it to the resolved subject.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

SID_CLEAN="clean-$$-${RANDOM}"
SID_TAINT="taint-$$-${RANDOM}"

step "S1 · Bob → send_email (untainted session, clean body)"
note "Session: $SID_CLEAN (never touched secret data)"
note "Expected: 200 OK — require(perm.email_send) ✓, pii-scan ✓, session clean"
SESSION_ID="$SID_CLEAN" call_send_email "$BOB" "$CLIENT"

step "S2 · Bob → get_compensation (taints the session)"
note "Session: $SID_TAINT"
note "Expected: 200 OK — and the policy's taint(secret, session) marks this session"
SESSION_ID="$SID_TAINT" call_get_compensation "$BOB" "$CLIENT" true

step "S3 · Bob → send_email (SAME session as S2, clean body)"
note "Session: $SID_TAINT (now carries label \"secret\" from S2)"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=session_tainted_secret"
note "Denied by the SESSION taint — NOT by pii-scan (the body is clean)"
note "This is the cross-tool data-flow control: read secrets → can't email out"
SESSION_ID="$SID_TAINT" call_send_email "$BOB" "$CLIENT"
