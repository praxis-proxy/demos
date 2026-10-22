#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Bob has email_send, but an SSN in the body triggers pii.detected.
# Expect JSON-RPC -32001, no upstream call, and an audit record of the attempt.

set -euo pipefail
source "$(dirname "$0")/_lib.sh"

step "Bob (HR + email_send) → send_email with SSN in body"
note "Triggered by: pii-scan plugin catches the SSN pattern in args"

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

reset_upstream
_print_response "$(_post_tool "$BOB" "$CLIENT" "$REQUEST_BODY")"

expect_status 200
expect_rpc_error -32001
expect_violation pii.detected
expect_upstream_calls 0

# A deny is still an event worth recording: the attempt is the interesting
# part, so the audit trail has to survive the refusal.
show_last_audit send_email
expect_audit_record send_email
finish
