#!/bin/bash
# Scenario 05 (deep dive): the gateway is killed mid-shift and restarted.
# The record stream says so explicitly, so nobody mistakes it for lost records.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

title "05  Gateway crash and restart: a new epoch, not a gap"
business "the operations team, after an unplanned gateway restart" \
         "every executor boot opens a new epoch; stream_seq restarts at 0 inside it" \
         "an auditor unable to tell a restart from deleted records"

BOB=$(token bob)
M=$(mark)
step "One call before the crash"
show_reply "get_compensation(EMP-005678)" "$(mcp "$BOB" "s05-$$" get_compensation '{"employee_id":"EMP-005678"}')"
before=$(since "$M" | tail -1 | jq -c '.unmapped."aid.stream" | {epoch, stream_seq}')

step "kill -9 the gateway, then start it again"
"$DEMO_DIR/tools/gateway.sh" kill9
ok "gateway killed"
"$DEMO_DIR/tools/gateway.sh" start
ok "gateway restarted"

step "One call after the restart"
show_reply "get_compensation(EMP-005678)" "$(mcp "$BOB" "s05-$$" get_compensation '{"employee_id":"EMP-005678"}')"
after=$(since "$M" | tail -1 | jq -c '.unmapped."aid.stream" | {epoch, stream_seq}')
info "last record before the crash: $before"
info "last record after the restart: $after"
since "$M" | jq -r '.attestation_list[0] | select(.prev_event == null) | "  genesis record of the new chain: " + .uid'

step "Shipping both sides of the restart to the ARE ledger"
ship "$M"

auditor "an explicit epoch boundary: the adapter reports EPOCH CHANGE and counts no gap,
         the new process starts a fresh chain at its genesis record, and the ledger's own chain
         runs straight through the restart."
