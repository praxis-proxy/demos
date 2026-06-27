#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env
ensure_artifacts

PRAXIS="$(praxis_url)"
OPENAI="https://api.openai.com"

[[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY is not set"
[[ -n "${OPENAI_MODEL:-}" ]]  || die "OPENAI_MODEL is not set"

AUTH_CONFIG_FD=""
setup_auth_fd() {
    local tmpfd
    exec {tmpfd}< <(printf 'header = "Authorization: Bearer %s"\n' "${OPENAI_API_KEY}")
    AUTH_CONFIG_FD="${tmpfd}"
}

request() {
    local label="$1" url="$2" body="$3" out_body="$4" out_headers="$5"
    local http_code

    info "${label}"
    setup_auth_fd
    http_code=$(curl -s -o "${out_body}" -D "${out_headers}" \
        -w '%{http_code}' \
        --connect-timeout 10 --max-time 120 \
        -H "Content-Type: application/json" \
        -K /dev/fd/${AUTH_CONFIG_FD} \
        "${url}/v1/responses" \
        -d "${body}")
    exec {AUTH_CONFIG_FD}<&- 2>/dev/null || true

    grep -vi '^authorization:' "${out_headers}" > "${out_headers}.tmp" && mv "${out_headers}.tmp" "${out_headers}"

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
        fail "${label}: HTTP ${http_code}"
        cat "${out_body}" >&2
        return 1
    fi

    ok "${label}: HTTP ${http_code}"
}

stream_request() {
    local label="$1" url="$2" body="$3" out_sse="$4" out_headers="$5"
    local http_code

    info "${label}"
    setup_auth_fd
    http_code=$(curl -sN -o "${out_sse}" -D "${out_headers}" \
        -w '%{http_code}' \
        --connect-timeout 10 --max-time 120 \
        -H "Content-Type: application/json" \
        -K /dev/fd/${AUTH_CONFIG_FD} \
        "${url}/v1/responses" \
        -d "${body}")
    exec {AUTH_CONFIG_FD}<&- 2>/dev/null || true

    grep -vi '^authorization:' "${out_headers}" > "${out_headers}.tmp" && mv "${out_headers}.tmp" "${out_headers}"

    if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
        fail "${label}: HTTP ${http_code}"
        cat "${out_sse}" >&2
        return 1
    fi

    ok "${label}: HTTP ${http_code}"
}

# 1. Aliased JSON request using the client model name
request \
    "1. Aliased model request (${CODEX_CLIENT_MODEL} → ${OPENAI_MODEL})" \
    "${PRAXIS}" \
    "{\"model\":\"${CODEX_CLIENT_MODEL}\",\"input\":\"Say hello in exactly three words.\",\"store\":false}" \
    "${ARTIFACTS_DIR}/smoke-alias.response.json" \
    "${ARTIFACTS_DIR}/smoke-alias.headers.txt"

# 2. JSON request without model (default injection)
request \
    "2. Default model injection (no model field)" \
    "${PRAXIS}" \
    "{\"input\":\"Say goodbye in exactly three words.\",\"store\":false}" \
    "${ARTIFACTS_DIR}/smoke-default.response.json" \
    "${ARTIFACTS_DIR}/smoke-default.headers.txt"

# 3. Streaming SSE request
stream_request \
    "3. Streaming SSE request through Praxis" \
    "${PRAXIS}" \
    "{\"model\":\"${CODEX_CLIENT_MODEL}\",\"input\":\"Count from one to five.\",\"stream\":true,\"store\":false}" \
    "${ARTIFACTS_DIR}/smoke-stream.sse" \
    "${ARTIFACTS_DIR}/smoke-stream.headers.txt"

# 4. Direct OpenAI control request
request \
    "4. Direct OpenAI control request (no Praxis)" \
    "${OPENAI}" \
    "{\"model\":\"${OPENAI_MODEL}\",\"input\":\"Say yes.\",\"store\":false}" \
    "${ARTIFACTS_DIR}/smoke-direct.response.json" \
    "${ARTIFACTS_DIR}/smoke-direct.headers.txt"

ok "All smoke requests completed. Evidence saved under $(relpath "${ARTIFACTS_DIR}")/"
