#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Bob (HR, perm.email_send) tries to send an email whose body
# carries an SSN-like pattern. APL's coarse `require(perm.email_send)`
# passes (Bob has the perm), but the PII scanner plugin walks the
# args, detects the SSN pattern, and denies the call.
#
# This demonstrates a field-level plugin in action — caught BEFORE
# the email backend is touched. The audit-logger plugin is ordered
# ahead of pii-scan in the policy chain (see cpex.yaml), so it emits
# its observation record before the PII deny short-circuits the
# chain — the denied attempt is still on the audit trail.
#
# Expected:
#   * HTTP 200 + JSON-RPC error -32001, data.violation=`pii.detected`
#     (gateway denials use the MCP Tools-spec JSON-RPC error envelope,
#     not HTTP 4xx)
#   * Backend (hr-mcp) NEVER receives the call — the deny is
#     enforced at the gateway plugin layer
#   * A JSON audit record describing the denied send_email attempt is
#     emitted to the gateway log and shown inline below (when the
#     gateway's output was teed to ./gateway.log, as restart.sh does)

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR + email_send) → send_email with SSN in body"
note "Expected: HTTP 200 + JSON-RPC error -32001, violation=pii.detected"
note "Triggered by: pii-scan plugin catches the SSN pattern in args"
note "Expected: audit-log still emits a record describing the deny"
note "Expected upstream: no inbound request (gateway plugin denied)"

BOB=$(mint bob)
CLIENT=$(mint hr-copilot)

REQUEST_BODY='{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "send_email",
    "arguments": {
      "to": "external@example.com",
      "subject": "compensation update",
      "body": "FYI — Jane Smith. Her SSN is 555-12-3456 if you need to update payroll."
    }
  }
}'

_print_response "$(_post_tool "$BOB" "$CLIENT" "$REQUEST_BODY")"

show_last_audit send_email
