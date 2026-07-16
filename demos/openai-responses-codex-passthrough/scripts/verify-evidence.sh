#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env

errors=0

check() {
    local label="$1"
    shift
    if "$@"; then
        ok "${label}"
    else
        fail "${label}"
        errors=$((errors + 1))
    fi
}

file_exists() { [[ -f "$1" && -s "$1" ]]; }
json_valid()  { jq empty "$1" 2>/dev/null; }

# --- Smoke response evidence ---

info "Verifying smoke-responses evidence"

check "Alias response file exists" \
    file_exists "${ARTIFACTS_DIR}/smoke-alias.response.json"

check "Alias response is valid JSON" \
    json_valid "${ARTIFACTS_DIR}/smoke-alias.response.json"

if file_exists "${ARTIFACTS_DIR}/smoke-alias.response.json"; then
    check "Alias response completed (has output)" \
        jq -e '.output | length > 0' "${ARTIFACTS_DIR}/smoke-alias.response.json" >/dev/null
fi

check "Default-injection response file exists" \
    file_exists "${ARTIFACTS_DIR}/smoke-default.response.json"

check "Default-injection response is valid JSON" \
    json_valid "${ARTIFACTS_DIR}/smoke-default.response.json"

if file_exists "${ARTIFACTS_DIR}/smoke-default.response.json"; then
    check "Default-injection response completed (has output)" \
        jq -e '.output | length > 0' "${ARTIFACTS_DIR}/smoke-default.response.json" >/dev/null
fi

# --- SSE evidence ---

info "Verifying SSE capture"

check "SSE capture file exists" \
    file_exists "${ARTIFACTS_DIR}/smoke-stream.sse"

if file_exists "${ARTIFACTS_DIR}/smoke-stream.sse"; then
    check "SSE capture contains data: events" \
        grep -q '^data: ' "${ARTIFACTS_DIR}/smoke-stream.sse"

    check "SSE capture contains terminal completion event" \
        grep -q '"type".*"response\.completed"' "${ARTIFACTS_DIR}/smoke-stream.sse"
fi

# --- Praxis log evidence ---

info "Verifying Praxis logs"

if file_exists "${LOG_FILE}"; then
    if grep -a 'route matched' "${LOG_FILE}" | grep -q 'openai'; then
        ok "Praxis log contains route match for openai cluster"
    else
        fail "Praxis log contains route match for openai cluster"
        errors=$((errors + 1))
    fi
else
    fail "Praxis log file not found: ${LOG_FILE}"
    errors=$((errors + 1))
fi

# --- Codex evidence ---

info "Verifying Codex evidence"

CODEX_JSONL="${ARTIFACTS_DIR}/codex.jsonl"
CODEX_STDERR="${ARTIFACTS_DIR}/codex.stderr.log"
PROOF_FILE="${ARTIFACTS_DIR}/codex-workspace/proof.txt"
EXPECTED_CONTENT="praxis-openai-codex-e2e"

check "Codex JSONL output exists" \
    file_exists "${CODEX_JSONL}"

if file_exists "${CODEX_JSONL}"; then
    check "Codex JSONL has content (lines > 0)" \
        test "$(wc -l < "${CODEX_JSONL}")" -gt 0
fi

check "Codex proof file exists" \
    file_exists "${PROOF_FILE}"

if file_exists "${PROOF_FILE}"; then
    actual="$(cat "${PROOF_FILE}")"
    check "Codex proof file has exact expected content" \
        test "${actual}" = "${EXPECTED_CONTENT}"
fi

# --- No credentials in artifacts ---

info "Checking artifacts for leaked credentials"

leaked=false
while IFS= read -r -d '' f; do
    if grep -qiE 'sk-proj-|sk-[a-zA-Z0-9]{20,}' "${f}" 2>/dev/null; then
        fail "Possible API key found in ${f}"
        leaked=true
    fi
done < <(find "${ARTIFACTS_DIR}" -type f -not -name '.gitignore' -print0 2>/dev/null)
if [[ "${leaked}" == "false" ]]; then
    ok "No API key patterns found in artifacts"
fi

# --- Summary ---

printf '\n'
if [[ ${errors} -gt 0 ]]; then
    die "${errors} verification check(s) failed"
fi

ok "All evidence checks passed"
