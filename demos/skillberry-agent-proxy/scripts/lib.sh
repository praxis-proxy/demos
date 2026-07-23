#!/usr/bin/env bash
# Shared utilities for the skillberry-agent-proxy demo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEMO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Cloned repos live here
TMP_DIR="${DEMO_DIR}/tmp"

# Paths
STORE_DIR="${TMP_DIR}/skillberry-store"
WORKER_DIR="${TMP_DIR}/skillberry-agent-praxis-poc"
STORE_VENV="${STORE_DIR}/.venv"
WORKER_VENV="${WORKER_DIR}/.venv"
CLIENT_VENV="${DEMO_DIR}/.venv"

# Repos
STORE_REPO="https://github.com/skillberry-ai/skillberry-store.git"
STORE_BRANCH="main"
WORKER_REPO="https://github.com/skillberry-ai/skillberry-agent-praxis-poc.git"
WORKER_BRANCH="main"

# Praxis
PRAXIS_ROOT="${PRAXIS_ROOT:-${HOME}/praxis}"
PRAXIS_BIN="${PRAXIS_BIN:-${PRAXIS_ROOT}/target/debug/praxis}"
TEMPLATE="${DEMO_DIR}/praxis.yaml.tmpl"
ARTIFACTS_DIR="${DEMO_DIR}/artifacts"
RUNTIME_CONFIG="${ARTIFACTS_DIR}/praxis.runtime.yaml"

# Ports
PRAXIS_PORT="${PRAXIS_PORT:-7000}"
STORE_PORT="${STORE_PORT:-8000}"
WORKER_PORT="${WORKER_PORT:-7010}"

# Log files
STORE_LOG="/tmp/skillberry-store.log"
WORKER_LOG="/tmp/worker.log"
PRAXIS_LOG="/tmp/praxis.log"

# PID files
STORE_PID_FILE="${DEMO_DIR}/.store.pid"
WORKER_PID_FILE="${DEMO_DIR}/.worker.pid"
PRAXIS_PID_FILE="${DEMO_DIR}/.praxis.pid"

# Python
PYTHON_VERSION="${PYTHON_VERSION:-python3.11}"

# ── Display helpers ──────────────────────────────────────────────────────────

info()    { printf '\033[0;36m▸ %s\033[0m\n' "$*"; }
ok()      { printf '\033[0;32m✔ %s\033[0m\n' "$*"; }
fail()    { printf '\033[0;31m✖ %s\033[0m\n' "$*" >&2; }
die()     { fail "$@"; exit 1; }
section() { printf '\n\033[1;35m══ %s ══\033[0m\n\n' "$1"; }

banner() {
    printf '\033[1m'
    cat <<'BANNER'

  ┌─────────────────────────────────────────────────────┐
  │   Skillberry Agent Proxy — Praxis Agentic Gateway   │
  │                                                     │
  │   Store (:8000) → Worker (:7010) → Praxis (:7000)  │
  └─────────────────────────────────────────────────────┘

BANNER
    printf '\033[0m'
}

# ── Port / process utilities ─────────────────────────────────────────────────

port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} "
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"${port}" -sTCP:LISTEN &>/dev/null
    else
        (echo >/dev/tcp/127.0.0.1/"${port}") 2>/dev/null
    fi
}

wait_for_health() {
    local url="$1" label="${2:-service}" timeout="${3:-60}"
    local elapsed=0
    while ! curl -sf "${url}" >/dev/null 2>&1; do
        sleep 2
        elapsed=$((elapsed + 2))
        if [[ ${elapsed} -ge ${timeout} ]]; then
            die "${label} health check failed after ${timeout}s (${url})"
        fi
    done
    ok "${label} is healthy (${url})"
}

stop_pid_file() {
    local pid_file="$1" label="${2:-process}" port="${3:-}"
    if [[ -f "${pid_file}" ]]; then
        local pid
        pid="$(cat "${pid_file}")"
        if kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            sleep 1
            kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
        fi
        rm -f "${pid_file}"
    fi
    # Also kill any process listening on the port (handles daemonized children)
    if [[ -n "${port}" ]]; then
        local pids
        pids="$(lsof -ti TCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
        if [[ -n "${pids}" ]]; then
            echo "${pids}" | xargs kill 2>/dev/null || true
            sleep 1
            pids="$(lsof -ti TCP:"${port}" -sTCP:LISTEN 2>/dev/null || true)"
            [[ -n "${pids}" ]] && echo "${pids}" | xargs kill -9 2>/dev/null || true
        fi
    fi
    ok "${label} stopped"
}
