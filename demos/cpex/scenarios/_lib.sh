# Shared helpers for the scenario scripts. Source from each script:
#
#   source "$(dirname "$0")/_lib.sh"

GATEWAY="${GATEWAY:-http://localhost:8090}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mint() {
  "$DEMO_DIR/mint-token.sh" "$1"
}

_print_response() {
  # Pretty-print: HTTP status + selected headers + body (jq if it parses,
  # raw otherwise). Always shows *something* — non-JSON error bodies and
  # gateway-emitted violation headers stay visible.
  local raw="$1"
  local status_line headers body
  status_line=$(printf '%s' "$raw" | awk 'NR==1 {sub(/\r$/, ""); print; exit}')
  headers=$(printf '%s' "$raw" | awk 'NR>1 && /^\r?$/ {exit} NR>1 {sub(/\r$/, ""); print}')
  body=$(printf '%s' "$raw" | awk 'p {print} /^\r?$/ {p=1}')
  echo "  $status_line"
  printf '%s\n' "$headers" | awk 'tolower($0) ~ /^x-policy|^content-type|^www-authenticate/ {print "  " $0}'
  if [ -n "$body" ]; then
    echo "  ---"
    if printf '%s' "$body" | jq . >/dev/null 2>&1; then
      printf '%s\n' "$body" | jq . | sed 's/^/  /'
    else
      printf '%s\n' "$body" | sed 's/^/  /'
    fi
  fi
}

_post_tool() {
  local user_token="$1" client_token="$2" body="$3"
  # Thread a CPEX session id when SESSION_ID is set: it lands in the
  # X-Session-Id header, which the praxis cpex filter maps to
  # agent.session_id so session-scoped taint labels persist across
  # separate tool calls in the same logical session. The cpex session
  # store binds it to the resolved subject (H(subject : session_id)),
  # so the same id under a different user is a different bucket. Unset
  # → no header → unchanged behavior.
  #
  # Resume a suspended approval when ELICITATION_ID is set: the id goes
  # in X-Policy-Elicitation-Id so the gateway *checks* the existing
  # elicitation instead of dispatching a fresh one. Add ELICITATION_PEEK
  # to only report status (-32121 once approved) WITHOUT running the tool
  # — used to detect approval before committing. See scenario 11.
  local extra=()
  [ -n "${SESSION_ID:-}" ] && extra+=(-H "X-Session-Id: $SESSION_ID")
  [ -n "${ELICITATION_ID:-}" ] && extra+=(-H "X-Policy-Elicitation-Id: $ELICITATION_ID")
  [ -n "${ELICITATION_PEEK:-}" ] && extra+=(-H "X-Policy-Elicitation-Peek: true")
  curl -isS --max-time 10 -X POST "$GATEWAY/mcp" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $client_token" \
    -H "X-User-Token: $user_token" \
    ${extra[@]+"${extra[@]}"} \
    --data "$body"
}

_http_body() {
  # Strip the HTTP status line + headers from a raw `curl -i` response,
  # leaving just the body (so it can be piped to jq).
  printf '%s' "$1" | awk 'p {print} /^\r?$/ {p=1}'
}

call_get_compensation() {
  local user_token="$1"
  local client_token="$2"
  local include_ssn="${3:-false}"
  local employee_id="${4:-EMP-001234}"

  local body
  body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_compensation",
    "arguments": {
      "employee_id": "$employee_id",
      "include_ssn": $include_ssn,
      "ssn": "would-be-removed-if-redact-fires"
    }
  }
}
EOF
  )
  _print_response "$(_post_tool "$user_token" "$client_token" "$body")"
}

call_send_email() {
  local user_token="$1"
  local client_token="$2"
  local email_body="${3:-Quarterly planning notes — nothing sensitive here.}"
  local to="${4:-partner@example.com}"

  local body
  body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "send_email",
    "arguments": {
      "to": "$to",
      "subject": "FYI",
      "body": "$email_body"
    }
  }
}
EOF
  )
  _print_response "$(_post_tool "$user_token" "$client_token" "$body")"
}

adjust_compensation_body() {
  # JSON-RPC body for adjust_compensation. Amount over the route's $10k
  # threshold triggers require_approval (manager sign-off via CIBA).
  local amount="$1" employee_id="${2:-EMP-001234}"
  cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "adjust_compensation",
    "arguments": {
      "employee_id": "$employee_id",
      "amount": $amount
    }
  }
}
EOF
}

call_adjust_compensation() {
  # One-shot adjust_compensation (used by scenario 10 for the under-
  # threshold path that needs no approval). Scenario 11 drives the
  # resume/peek flow directly via _post_tool + ELICITATION_ID.
  local user_token="$1" client_token="$2" amount="$3" employee_id="${4:-EMP-001234}"
  _print_response "$(_post_tool "$user_token" "$client_token" "$(adjust_compensation_body "$amount" "$employee_id")")"
}

show_last_audit() {
  # Surface the most recent audit-log record for the named tool so a
  # scenario can *show* its audit trail inline rather than asserting
  # one exists. Reads the gateway's teed log (restart.sh writes
  # ./gateway.log); silently no-ops when the gateway was started
  # straight to a terminal and no log file is on disk.
  local tool="$1"
  local log="$DEMO_DIR/gateway.log"
  [ -f "$log" ] || return 0
  local rec
  rec=$(grep '"plugin":"audit-log"' "$log" 2>/dev/null | grep "\"name\":\"$tool\"" | tail -1) || true
  [ -n "$rec" ] || return 0
  echo "  ---"
  note "audit-log record emitted for this attempt:"
  if printf '%s' "$rec" | jq . >/dev/null 2>&1; then
    printf '%s\n' "$rec" | jq . | sed 's/^/  /'
  else
    printf '  %s\n' "$rec"
  fi
}

step() {
  echo
  echo "============================================================"
  echo "$@"
  echo "============================================================"
}

note() {
  echo "  ▸ $*"
}
