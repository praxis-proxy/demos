#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Cross-principal taint isolation. Session taint is keyed by the
# resolved subject, not the raw X-Session-Id: the cpex session store
# binds it as H(subject : session_id). So the *same* session id under
# two different users resolves to two different buckets — one user's
# taint can't bleed into another's.
#
#   S1 bob  send_email     (sid=baseline)  → 200 OK   (clean baseline)
#   S2 eve  get_compensation (sid=shared)  → 200 OK   (taints H(eve:shared))
#   S3 bob  send_email     (sid=shared)    → 200 OK   (H(bob:shared) is a
#      different bucket; bob never accessed secrets, so no taint inherited)
#
# Pre-isolation (a raw, un-subject-scoped session key) S3 would have
# been denied with session_tainted_secret. The 200 proves the scoping.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

BOB=$(mint bob)
EVE=$(mint eve)
CLIENT=$(mint hr-copilot)

SID_BASELINE="baseline-$$-${RANDOM}"
SID_SHARED="shared-$$-${RANDOM}"

step "S1 · Bob → send_email (fresh session, clean body)"
note "Session: $SID_BASELINE (never touched secret data)"
note "Expected: 200 OK — baseline, bob can send mail from a clean session"
SESSION_ID="$SID_BASELINE" call_send_email "$BOB" "$CLIENT"

step "S2 · Eve → get_compensation (taints EVE's bucket for the shared id)"
note "Session: $SID_SHARED (bound to eve's subject → H(eve:$SID_SHARED))"
note "Expected: 200 OK — eve has role.hr; taint(secret, session) fires"
SESSION_ID="$SID_SHARED" call_get_compensation "$EVE" "$CLIENT" true

step "S3 · Bob → send_email, SAME session id as eve used, clean body"
note "Session: $SID_SHARED (bound to bob's subject → H(bob:$SID_SHARED))"
note "Expected: 200 OK — bob's bucket != eve's, so bob does NOT inherit her taint"
note "This is the subject-scoping guarantee: taint can't cross principals"
SESSION_ID="$SID_SHARED" call_send_email "$BOB" "$CLIENT"
