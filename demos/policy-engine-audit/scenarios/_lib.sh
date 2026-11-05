#!/bin/bash
# Shared helpers for the policy-engine-audit scenarios.
#
# Every scenario has the same three beats:
#   business()  who is acting, what policy says, what risk is avoided
#   (actions)   real tool calls through the Praxis gateway
#   auditor()   what the auditor gets: the OCSF records the sink wrote for
#               exactly those calls, shipped to the ARE ledger as receipts
#
# Set DEEP_DIVE=1 to also print the record fields behind each claim.

PRAXIS_URL="${PRAXIS_URL:-http://127.0.0.1:8090/mcp}"
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8081}"
REALM="${REALM:-cpex-demo}"
LEDGER_GRPC="${LEDGER_GRPC:-localhost:19292}"
HR_MCP_URL="${HR_MCP_URL:-http://127.0.0.1:9100}"

SCENARIO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "$SCENARIO_DIR/.." && pwd)"
# The ledger checkout tools/fetch-ledger.sh makes (adapter, proof explorer, SDK).
REPO_DIR="$DEMO_DIR/.ledger"
OUT="$DEMO_DIR/out"
# Raw gateway stderr: OCSF records, one JSON object per line, plus any
# pre-logging bootstrap lines. records() keeps only the JSON.
GATEWAY_STDERR="$OUT/gateway.stderr"
export PYTHONPATH="$REPO_DIR/sdks/python${PYTHONPATH:+:$PYTHONPATH}"

BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
GREEN="\033[92m"; RED="\033[91m"; CYAN="\033[96m"; YELLOW="\033[93m"; PURPLE="\033[95m"

ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
fail()  { echo -e "  ${RED}✗${RESET} $1"; exit 1; }
info()  { echo -e "  ${DIM}$1${RESET}"; }
step()  { echo -e "\n${CYAN}$1${RESET}"; }

title() {
    echo ""
    echo -e "${BOLD}━━━ $1 ━━━${RESET}"
}

# business "<who>" "<policy>" "<risk avoided>"
business() {
    echo -e "  ${YELLOW}Who${RESET}     $1"
    echo -e "  ${YELLOW}Policy${RESET}  $2"
    echo -e "  ${YELLOW}Risk${RESET}    $3"
}

# auditor "<sentence>"
auditor() {
    echo ""
    echo -e "  ${PURPLE}${BOLD}What the auditor gets${RESET}  $1"
}

deep() { [ "${DEEP_DIVE:-0}" = "1" ]; }

# ---------------------------------------------------------------------------
# Identity and tool calls
# ---------------------------------------------------------------------------

# token <user>: a Keycloak access token for one of the realm's demo users
# (bob, alice, eve, charlie; password = username), via the agent's client.
token() {
    curl -sS -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
        -d grant_type=password -d client_id=hr-copilot -d client_secret=hr-copilot-secret \
        -d "username=$1" -d "password=$1" -d scope=openid |
        jq -r .access_token
}

# mcp <token> <session> <tool> <arguments-json>: one tools/call through the
# gateway. Prints the JSON-RPC reply.
mcp() {
    local body
    body=$(jq -cn --arg tool "$3" --argjson args "$4" \
        '{jsonrpc:"2.0", id:1, method:"tools/call", params:{name:$tool, arguments:$args}}')
    curl -sS "$PRAXIS_URL" \
        -H "Authorization: Bearer $1" -H "X-User-Token: $1" -H "X-Session-Id: $2" \
        -H "Content-Type: application/json" -d "$body"
}

# show_reply <label> <reply>: one line, allowed or denied.
show_reply() {
    if echo "$2" | jq -e '.error' >/dev/null; then
        echo -e "    ${RED}✗ $1: DENIED${RESET}  $(echo "$2" | jq -r '.error.message + "  [" + (.error.data.violation // "") + "]"')"
    else
        echo -e "    ${GREEN}✓ $1${RESET}  ${DIM}$(echo "$2" | jq -r '.result.content[0].text' | tr -d '\n' | cut -c1-90)…${RESET}"
    fi
}

# ---------------------------------------------------------------------------
# OCSF records
# ---------------------------------------------------------------------------

# records: every OCSF record the gateway has written so far.
records() { grep '^{' "$GATEWAY_STDERR" 2>/dev/null || true; }

# mark: how many records exist now. Pass it to since() after the actions.
mark() { records | wc -l | tr -d ' '; }

# since <mark>: the records written after <mark>.
since() { records | tail -n +"$(($1 + 1))"; }

# The sink fires at every pipeline verdict, so one tool call yields several
# records: identity, token exchange (when the route delegates), the route's
# pre_invocation ruling, and its response-side ruling.
summarize() {
    jq -r '
      def pad($n): tostring | . + (" " * ([$n - length, 0] | max));
      def phase: (.unmapped."aid.decision".steps | map(.plugin) | join(",")) as $p
        | if ($p | test("::pre$")) then "authorize"
          elif ($p | test("::post$")) then "response"
          elif ($p | test("jwt")) then "identity"
          elif ($p | test("oauth")) then "token exchange"
          elif $p == "" then "forward"
          else $p end;
      # Blocked rows in red (ANSI), so a deny stands out in the records pane.
      (if .disposition == "Blocked" then "\u001b[91m" else "" end)
        + "    " + ("seq " + (.unmapped."aid.stream".stream_seq | tostring) | pad(8))
        + ((.tool.name // "-") | pad(18))
        + (phase | pad(16))
        + ((.disposition + (if .action == "Modified" then " (modified)" else "" end)) | pad(20))
        + (.status_code // "")
        + (if .disposition == "Blocked" then "\u001b[0m" else "" end)'
}

# ship <mark>: send the records since <mark> through the ledger's CPEX
# adapter, which issues one hash-chained receipt per record.
ship() {
    local batch="$OUT/batch.ndjson"
    since "$1" > "$batch"
    python3 "$REPO_DIR/adapters/cpex/cpex_to_ledger.py" --endpoint "$LEDGER_GRPC" --file "$batch" 2>&1 |
        grep -E '^\s+\[|NOTE|WARNING|Written' | sed 's/^/  /'
}

# receipt_for <mark> <jq-filter>: verify the ledger receipt for the record
# the filter picks (as a metadata.uid) out of the records since <mark>.
receipt_for() {
    local uid
    uid=$(since "$1" | jq -rs "$2" )
    python3 "$DEMO_DIR/tools/receipt.py" --endpoint "$LEDGER_GRPC" --uid "$uid" | sed 's/^/  /'
}
