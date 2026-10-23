# shellcheck shell=bash
# Shared helpers for the scenario scripts. Source from each script:
#
#   source "$(dirname "$0")/_lib.sh"
#
# Sourced, never executed, so it carries a shell directive rather than a
# shebang.

GATEWAY="${GATEWAY:-http://localhost:8090}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mint() {
  if [ "${USE_VERIFY:-}" = "true" ]; then
    "$DEMO_DIR/mint-verify-token.sh" "$1"
  else
    "$DEMO_DIR/mint-token.sh" "$1"
  fi
}

token_sub() {
  # The `sub` claim of a minted token, so a scenario can assert that an
  # asserted header carries the caller's real subject id rather than whatever
  # the caller claimed. Decode only: the gateway does the verifying.
  local payload
  payload="$(printf '%s' "$1" | cut -d. -f2)"
  # base64url, and jq wants the padding.
  while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
  printf '%s' "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -r '.sub // empty'
}

_print_response() {
  # Pretty-print: HTTP status + selected headers + body (jq if it parses,
  # raw otherwise). Always shows *something* — non-JSON error bodies and
  # gateway-emitted violation headers stay visible.
  local raw="$1"
  local status_line headers body
  # Stash for the expect_* helpers. A scenario asserts against the call it
  # just made, so the last response is the only one that needs keeping.
  LAST_RAW="$raw"
  status_line=$(printf '%s' "$raw" | awk 'NR==1 {sub(/\r$/, ""); print; exit}')
  headers=$(printf '%s' "$raw" | awk 'NR>1 && /^\r?$/ {exit} NR>1 {sub(/\r$/, ""); print}')
  body=$(printf '%s' "$raw" | awk 'p {print} /^\r?$/ {p=1}')
  LAST_STATUS="$(printf '%s' "$status_line" | awk '{print $2}')"
  LAST_HEADERS="$headers"
  LAST_BODY="$body"
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
  # Thread a session id when SESSION_ID is set: it lands in the
  # X-Session-Id header, which the policy filter maps to
  # agent.session_id so session-scoped taint labels persist across
  # separate tool calls in the same logical session. The engine's session
  # store binds it to the resolved subject (H(subject : session_id)),
  # so the same id under a different user is a different bucket. Unset
  # → no header → unchanged behavior.
  #
  # Resume a suspended approval when ELICITATION_ID is set: the id goes
  # in X-Policy-Elicitation-Id so the gateway *checks* the existing
  # elicitation instead of dispatching a fresh one. Add ELICITATION_PEEK
  # to only report status (-32121 once approved) WITHOUT running the tool
  # — used to detect approval before committing. See scenario 11.
  #
  # Spoof an asserted header when SPOOF_HEADER is set: the client claims a
  # header the `assertions:` contract also targets. An entry removes its target
  # before injecting, so the upstream must see the engine's value and never
  # this one. Used by scenario 12.
  local extra=()
  [ -n "${SPOOF_HEADER:-}" ] && extra+=(-H "$SPOOF_HEADER")
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

call_search_repos() {
  # search_repos is the PDP-gated tool (Cedar / CEL / Rego, per config).
  # Scenarios 04, 05 and 06 used to inline their own curl, which meant their
  # responses never reached the expect_* helpers.
  local user_token="$1" client_token="$2" visibility="${3:-internal}" repo_name="${4:-}"
  local args
  if [ -n "$repo_name" ]; then
    args="{ \"repo_name\": \"$repo_name\", \"visibility\": \"$visibility\" }"
  else
    args="{ \"visibility\": \"$visibility\" }"
  fi
  local body
  body=$(cat <<EOF
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "search_repos",
    "arguments": $args
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
  _wait_for_audit "$tool" || true
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

# ---------------------------------------------------------------------------
# Assertions
#
# Each helper prints the same line the scenario used to print as a `note`, and
# then checks it. The narration IS the assertion, so a claim cannot drift away
# from what the gateway does without turning the scenario red.
#
# Failures accumulate rather than exiting at the first one: a scenario that
# makes four claims is more useful when it reports all four.
# ---------------------------------------------------------------------------

FAILURES=0

pass_() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail_() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# Every scenario ends with this. Without it a failed expectation would print
# red and still exit 0, which is the exact problem these replace.
finish() {
  if [ "$FAILURES" -ne 0 ]; then
    printf '\n  \033[1;31m%s expectation(s) failed\033[0m\n' "$FAILURES"
    exit 1
  fi
  printf '\n  \033[1;32mall expectations met\033[0m\n'
}

expect_status() {
  local want="$1"
  if [ "${LAST_STATUS:-}" = "$want" ]; then
    pass_ "HTTP $want"
  else
    fail_ "expected HTTP $want, got ${LAST_STATUS:-<none>}"
  fi
}

# The gateway reports policy denials in a JSON-RPC error envelope over HTTP
# 200, per MCP's Tools spec, so the code is the thing worth asserting.
expect_rpc_error() {
  local want="$1" got
  got="$(printf '%s' "${LAST_BODY:-}" | jq -r '.error.code // empty' 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass_ "JSON-RPC error $want"
  else
    fail_ "expected JSON-RPC error $want, got ${got:-<none>}"
  fi
}

expect_rpc_ok() {
  if printf '%s' "${LAST_BODY:-}" | jq -e '.result' >/dev/null 2>&1; then
    pass_ "JSON-RPC result (no error)"
  else
    fail_ "expected a JSON-RPC result, got: $(printf '%s' "${LAST_BODY:-}" | jq -c '.error // .' 2>/dev/null)"
  fi
}

expect_violation() {
  local want="$1" hdr body
  hdr="$(printf '%s\n' "${LAST_HEADERS:-}" | awk 'tolower($1) == "x-policy-violation:" {print $2}' | tr -d '\r')"
  body="$(printf '%s' "${LAST_BODY:-}" | jq -r '.error.data.violation // empty' 2>/dev/null)"
  if [ "$hdr" = "$want" ] && [ "$body" = "$want" ]; then
    pass_ "violation=$want (header and body agree)"
  elif [ "$hdr" = "$want" ] || [ "$body" = "$want" ]; then
    fail_ "violation=$want in only one place (header='$hdr' body='$body')"
  else
    fail_ "expected violation=$want, got header='${hdr:-<none>}' body='${body:-<none>}'"
  fi
}

expect_no_violation() {
  local hdr
  hdr="$(printf '%s\n' "${LAST_HEADERS:-}" | awk 'tolower($1) == "x-policy-violation:" {print $2}' | tr -d '\r')"
  if [ -z "$hdr" ]; then
    pass_ "no X-Policy-Violation"
  else
    fail_ "expected no violation, got '$hdr'"
  fi
}

# The tool result travels as a JSON string inside result.content[].text, so
# matching the decoded payload beats grepping the escaped envelope.
_result_text() {
  printf '%s' "${LAST_BODY:-}" | jq -r '.result.content[0].text // empty' 2>/dev/null
}

expect_result_field() {
  local field="$1" want="$2" got
  got="$(_result_text | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass_ "result.$field = $want"
  else
    fail_ "expected result.$field = '$want', got '${got:-<none>}'"
  fi
}

# The audit-logger is a reference plugin, so "it still fired on a denial" is a
# claim about plugin ordering worth checking, not just showing.
# The plugin writes its record as the request finishes, and the gateway's
# stdout reaches the log file on its own schedule, so a read immediately after
# the response can miss a record that is on its way. Poll briefly rather than
# racing it.
_wait_for_audit() {
  local tool="$1" log="$DEMO_DIR/gateway.log" i
  [ -f "$log" ] || return 1
  for i in $(seq 1 30); do
    if grep '"plugin":"audit-log"' "$log" 2>/dev/null | grep -q "\"name\":\"$tool\""; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

expect_audit_record() {
  local tool="$1" log="$DEMO_DIR/gateway.log"
  if [ ! -f "$log" ]; then
    note "skipping audit assertion: no $log (gateway not started by restart.sh)"
    return 0
  fi
  if _wait_for_audit "$tool"; then
    pass_ "audit-log recorded a $tool attempt"
  else
    fail_ "expected an audit-log record for $tool, found none"
  fi
}

# ---------------------------------------------------------------------------
# Upstream assertions
#
# `_reset_upstream` before the call, these after it. They read the mock MCP
# server's recorder (hr-mcp-server/server.py), which is the only way to check
# the claims that matter most: that a denied call never left the gateway, that
# delegation swapped the token, and that the asserted headers are the engine's.
# ---------------------------------------------------------------------------

UPSTREAM="${UPSTREAM:-http://localhost:9100}"

reset_upstream() {
  curl -fsS -X POST "$UPSTREAM/_reset" >/dev/null 2>&1 \
    || note "warning: could not reach the upstream recorder at $UPSTREAM"
}

_upstream() { curl -fsS "$UPSTREAM/_requests" 2>/dev/null; }

expect_upstream_calls() {
  local want="$1" got
  got="$(_upstream | jq -r '.count // empty')"
  if [ "$got" = "$want" ]; then
    if [ "$want" = "0" ]; then
      pass_ "upstream never saw the call (short-circuited at the gateway)"
    else
      pass_ "upstream saw $want inbound call(s)"
    fi
  else
    fail_ "expected $want upstream call(s), got ${got:-<unreachable>}"
  fi
}

# Which token the upstream was handed. The demo's whole delegation story is
# that this is an IdP-minted token for the tool's audience, not the caller's.
expect_upstream_audience() {
  local want="$1" got
  got="$(_upstream | jq -r '.requests[-1].headers.authorization.jwt.aud // [] | join(",")' 2>/dev/null)"
  case ",$got," in
    *",$want,"*) pass_ "upstream authorization aud=$want (IdP-minted, not the caller's token)" ;;
    *) fail_ "expected upstream authorization aud=$want, got '${got:-<none>}'" ;;
  esac
}

expect_upstream_header() {
  local name="$1" want="$2" got
  got="$(_upstream | jq -r --arg h "$name" '.requests[-1].headers[$h] // empty' 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass_ "upstream $name = $want"
  else
    fail_ "expected upstream $name = '$want', got '${got:-<absent>}'"
  fi
}

expect_upstream_no_header() {
  local name="$1" got
  got="$(_upstream | jq -r --arg h "$name" 'if (.requests[-1].headers | has($h)) then "present" else "" end' 2>/dev/null)"
  if [ -z "$got" ]; then
    pass_ "upstream never saw $name"
  else
    fail_ "expected upstream not to see $name, but it was present"
  fi
}

# What the tool was actually invoked with, after any request-side rewrite.
expect_upstream_arg() {
  local name="$1" want="$2" got
  got="$(_upstream | jq -r --arg a "$name" '.requests[-1].arguments[$a] // empty' 2>/dev/null)"
  if [ "$got" = "$want" ]; then
    pass_ "upstream args.$name = $want"
  else
    fail_ "expected upstream args.$name = '$want', got '${got:-<absent>}'"
  fi
}
