#!/bin/bash
# Scenario 01: an HR partner reads a salary. Allowed, and provably so.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

title "01  HR reads compensation: allowed, with evidence"
business "Bob, HR business partner, through the HR copilot agent" \
         "only the HR role may read compensation; the call goes out on a scoped workday-api token" \
         "an allow nobody can prove later is as bad as no control at all"

M=$(mark)
step "Bob's agent asks for Jane Smith's compensation"
BOB=$(token bob)
show_reply "get_compensation(EMP-001234)" \
    "$(mcp "$BOB" "s01-$$" get_compensation '{"employee_id":"EMP-001234"}')"

step "OCSF records the gateway wrote for that one call"
since "$M" | summarize
if deep; then
    info "the authorize record, abridged:"
    since "$M" | jq -c 'select(.tool.name=="get_compensation") | {class_uid, activity_name, disposition, actor, tool, stream: .unmapped."aid.stream", prev: .attestation_list[0].prev_event.uid, signed_by: .unmapped.signature_key_id}' | head -1 | sed 's/^/    /'
fi

step "Shipping them to the ARE ledger"
ship "$M"
receipt_for "$M" 'map(select(.tool.name=="get_compensation")) | last | .metadata.uid'

auditor "an OCSF API Activity event per ruling (identity, token exchange, authorize,
         response), each hash-chained to the last and DSSE-signed by the gateway, plus a ledger
         receipt for each that verifies without trusting the gateway."
