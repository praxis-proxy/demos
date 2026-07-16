#!/usr/bin/env bash
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${DEMO_DIR}/artifacts"
TEMPLATE="${DEMO_DIR}/praxis.yaml.tmpl"
RUNTIME_CONFIG="${ARTIFACTS_DIR}/praxis.runtime.yaml"
PID_FILE="${ARTIFACTS_DIR}/praxis.pid"
LOG_FILE="${ARTIFACTS_DIR}/praxis.log"

PRAXIS_PORT="${PRAXIS_PORT:-18480}"
CODEX_CLIENT_MODEL="${CODEX_CLIENT_MODEL:-codex-openai-demo}"

load_env() {
    if [[ -f "${DEMO_DIR}/.env" ]]; then
        set -a
        # shellcheck source=/dev/null
        . "${DEMO_DIR}/.env"
        set +a
    fi
}

ensure_artifacts() {
    mkdir -p "${ARTIFACTS_DIR}"
}

resolve_praxis_bin() {
    if [[ -n "${PRAXIS_BIN:-}" ]]; then
        printf '%s' "${PRAXIS_BIN}"
    else
        command -v praxis 2>/dev/null || true
    fi
}

praxis_url() {
    printf 'http://127.0.0.1:%s' "${PRAXIS_PORT}"
}

port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnH "sport = :${port}" 2>/dev/null | grep -q .
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"${port}" -sTCP:LISTEN -t &>/dev/null
    else
        (echo >/dev/tcp/127.0.0.1/"${port}") 2>/dev/null
    fi
}

pid_is_praxis() {
    local pid="$1"
    kill -0 "${pid}" 2>/dev/null || return 1
    local cmd
    cmd="$(ps -p "${pid}" -o comm= 2>/dev/null)" || return 1
    [[ "${cmd}" == "praxis" ]]
}

relpath() { printf '%s' "${1#"${DEMO_DIR}"/}"; }

info() { printf '\033[1;36m▸ %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$1"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$1" >&2; }
die()  { fail "$1"; exit 1; }
