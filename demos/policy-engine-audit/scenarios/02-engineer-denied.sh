#!/bin/bash
# Scenario 02: an engineer's agent tries to read salaries. Denied at the gateway.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

title "02  Engineer reads compensation: denied before the HR system sees it"
business "Alice, principal engineer, through the same HR copilot agent" \
         "require(role.hr) on get_compensation" \
         "an over-broad agent leaking salary data to people outside HR"

M=$(mark)
step "Alice's agent asks for Jane Smith's compensation"
ALICE=$(token alice)
show_reply "get_compensation(EMP-001234)" \
    "$(mcp "$ALICE" "s02-$$" get_compensation '{"employee_id":"EMP-001234"}')"

step "OCSF records"
since "$M" | summarize
if deep; then
    info "the deny record names the rule and the principal:"
    since "$M" | jq -c 'select(.action=="Denied") | {action, disposition, status_code, status_detail, actor}' | sed 's/^/    /'
fi

step "Shipping them to the ARE ledger"
ship "$M"
receipt_for "$M" 'map(select(.action=="Denied")) | last | .metadata.uid'

auditor "a signed deny record naming who asked (actor), for what (tool), and which rule
         refused it (status_code points at the policy line), receipted in the ledger."
