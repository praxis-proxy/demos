#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

LIVE=false
KEEP_PRAXIS=false
ALLOW_DANGER=false

for arg in "$@"; do
    case "${arg}" in
        --live)                      LIVE=true ;;
        --keep-praxis)               KEEP_PRAXIS=true ;;
        --allow-danger-full-access)  ALLOW_DANGER=true ;;
        --help|-h)
            cat <<'EOF'
Usage: run-narrative.sh --live [--keep-praxis] [--allow-danger-full-access]

All-in-one narrated demo: Codex CLI -> Praxis -> OpenAI Responses API.
Runs check-prereqs, starts Praxis, sends smoke requests, runs Codex,
verifies evidence, and stops Praxis.

This demo makes live, paid API calls to OpenAI.

Options:
  --live                         Required. Confirms intent to make paid calls.
  --keep-praxis                  Leave Praxis running after the demo finishes.
  --allow-danger-full-access     Required when CODEX_SANDBOX_MODE is set to
                                 danger-full-access. Only suitable for an
                                 externally isolated environment.
  --help, -h                     Show this help and exit.

Environment:
  See .env.example for required variables. Source .env before running.
EOF
            exit 0
            ;;
        *)
            fail "Unknown argument: ${arg}"
            echo "Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

if [[ "${LIVE}" != "true" ]]; then
    fail "This demo makes live, paid OpenAI API calls."
    echo "Pass --live to confirm." >&2
    exit 1
fi

if [[ "${CODEX_SANDBOX_MODE:-}" == "danger-full-access" && "${ALLOW_DANGER}" != "true" ]]; then
    fail "CODEX_SANDBOX_MODE=danger-full-access is set."
    echo "This disables Codex sandboxing entirely. It is only suitable for" >&2
    echo "an externally isolated environment (container, VM, disposable host)." >&2
    echo "Add --allow-danger-full-access to confirm." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

EXIT_CODE=0
PRAXIS_STARTED=false

cleanup() {
    local rc=${EXIT_CODE}
    if [[ "${PRAXIS_STARTED}" == "true" && "${KEEP_PRAXIS}" != "true" ]]; then
        printf '\n'
        info "Stopping Praxis"
        "${SCRIPT_DIR}/stop-praxis.sh" 2>&1 || true
    elif [[ "${KEEP_PRAXIS}" == "true" && "${PRAXIS_STARTED}" == "true" ]]; then
        info "Praxis left running (--keep-praxis). Stop with: ./scripts/stop-praxis.sh"
    fi
    exit "${rc}"
}
trap cleanup EXIT INT TERM

section() {
    printf '\n\033[1;35m== %s ==\033[0m\n\n' "$1"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

printf '\033[1m'
cat <<'BANNER'

  Codex CLI -> Praxis -> OpenAI Responses API
  Live interoperability demo (paid API calls)

BANNER
printf '\033[0m'

# ---------------------------------------------------------------------------
# 1/5 Preflight
# ---------------------------------------------------------------------------

section "1/5 Preflight"

load_env
"${SCRIPT_DIR}/check-prereqs.sh"

# ---------------------------------------------------------------------------
# 2/5 Start Praxis
# ---------------------------------------------------------------------------

section "2/5 Start Praxis"

info "Starting Praxis in the background on 127.0.0.1:${PRAXIS_PORT}"
"${SCRIPT_DIR}/start-praxis.sh" &>/dev/null &
BG_PID=$!
PRAXIS_STARTED=true

WAIT_SECS=10
for i in $(seq 1 "${WAIT_SECS}"); do
    if port_in_use "${PRAXIS_PORT}"; then
        ok "Praxis is listening on port ${PRAXIS_PORT}"
        break
    fi
    if ! kill -0 "${BG_PID}" 2>/dev/null; then
        fail "Praxis exited before the port opened"
        info "Last 15 lines of ${LOG_FILE}:"
        tail -15 "${LOG_FILE}" 2>/dev/null >&2 || true
        EXIT_CODE=1
        exit 1
    fi
    sleep 1
done

if ! port_in_use "${PRAXIS_PORT}"; then
    fail "Praxis did not open port ${PRAXIS_PORT} within ${WAIT_SECS}s"
    info "Last 15 lines of ${LOG_FILE}:"
    tail -15 "${LOG_FILE}" 2>/dev/null >&2 || true
    EXIT_CODE=1
    exit 1
fi

# ---------------------------------------------------------------------------
# 3/5 Responses Smoke Checks
# ---------------------------------------------------------------------------

section "3/5 Responses Smoke Checks"

cat <<'DESC'
Four live requests prove the Praxis filter pipeline:

  1. Aliased model    - client sends the demo alias; Praxis rewrites it
  2. Default injection - no model field; Praxis injects the configured default
  3. SSE streaming     - chunked Responses stream forwarded through the proxy
  4. Direct control    - same key hits OpenAI directly to confirm baseline

DESC

if ! "${SCRIPT_DIR}/smoke-responses.sh"; then
    EXIT_CODE=1
    exit 1
fi

# ---------------------------------------------------------------------------
# 4/5 Codex Tool Loop
# ---------------------------------------------------------------------------

section "4/5 Codex Tool Loop"

cat <<'DESC'
Codex CLI uses Praxis as a custom Responses provider:

  - wire_api = responses, base URL = Praxis loopback
  - Client model is the demo alias; Praxis rewrites before forwarding
  - Codex owns tool execution locally and returns function_call_output
  - Task: create proof.txt with exact content, read it back

DESC

if ! "${SCRIPT_DIR}/run-codex.sh"; then
    EXIT_CODE=1
    exit 1
fi

# ---------------------------------------------------------------------------
# 5/5 Evidence Verification
# ---------------------------------------------------------------------------

section "5/5 Evidence Verification"

if ! "${SCRIPT_DIR}/verify-evidence.sh"; then
    EXIT_CODE=1
    exit 1
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
printf '\033[1;32m'
cat <<'SUMMARY'
  Demo complete. Captured evidence:

    - Alias and default-injection JSON requests completed (HTTP 200)
    - SSE stream contains data: events and response.completed
    - Praxis logs show effective-model route selection to OpenAI cluster
    - Codex JSONL session log produced
    - Proof file contains exact expected content
    - No API key patterns found in artifacts

SUMMARY
printf '\033[0m'
