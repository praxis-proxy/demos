#!/bin/bash
# Scenario 04: an HR user without SSN clearance gets the record with the SSN
# removed, and the audit trail proves a change was made without holding the SSN.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

title "04  SSN redacted in flight: the record proves it without repeating it"
business "Eve, HR generalist (HR role, no view_ssn permission)" \
         "result.ssn is redacted unless the caller holds perm.view_ssn" \
         "PII reaching an unauthorised user, or landing in the audit log itself"

M=$(mark)
step "Eve's agent asks for Jane Smith's record including the SSN"
EVE=$(token eve)
reply=$(mcp "$EVE" "s04-$$" get_compensation '{"employee_id":"EMP-001234","include_ssn":true}')
show_reply "get_compensation(include_ssn=true)" "$reply"
echo "$reply" | jq -r '.result.content[0].text' | jq -r '"    ssn field the agent received: " + .ssn'

step "OCSF records"
since "$M" | summarize
since "$M" | jq -r 'select(.unmapped."aid.decision".steps[0].plugin | test("::post$"))
    | .unmapped."aid.content" | "    response digests: in " + .input_hash[0:22] + "…  out " + .output_hash[0:22] + "…"'
since "$M" | jq -e 'select(.unmapped."aid.content".input_hash != .unmapped."aid.content".output_hash)' >/dev/null &&
    ok "input and output digests differ: the gateway changed the response"
if since "$M" | grep -q '123-45-6789'; then fail "the SSN is in the audit record"; else ok "the SSN appears nowhere in the audit records"; fi

step "Shipping them to the ARE ledger"
ship "$M"
receipt_for "$M" 'map(select(.unmapped."aid.decision".steps[0].plugin | test("::post$"))) | last | .metadata.uid'

auditor "proof that the response was modified (allow-after-modify, differing content
         digests) without the audit trail ever holding the SSN it removed."
