#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env

errors=0

require_cmd() {
    local cmd="$1" purpose="$2"
    if command -v "${cmd}" &>/dev/null; then
        ok "${cmd} found"
    else
        fail "${cmd} not found — ${purpose}"
        errors=$((errors + 1))
    fi
}

require_cmd bash   "shell interpreter"
require_cmd curl   "HTTP requests"
require_cmd jq     "JSON processing"
require_cmd envsubst "template rendering (gettext)"

info "Checking Codex CLI"
if command -v codex &>/dev/null; then
    codex_version="$(codex --version 2>/dev/null || echo unknown)"
    ok "codex found (${codex_version})"

    codex_help="$(codex exec --help 2>&1)"
    missing_flags=()
    for flag in "--json" "--skip-git-repo-check" "--ephemeral" "--ignore-user-config" "--ignore-rules" "-C" "-m" "-s" "-c"; do
        if ! grep -qF -- "${flag}" <<< "${codex_help}"; then
            missing_flags+=("${flag}")
        fi
    done
    if [[ ${#missing_flags[@]} -gt 0 ]]; then
        fail "Codex CLI is missing flags used by run-codex.sh: ${missing_flags[*]}"
        errors=$((errors + 1))
    else
        ok "Codex CLI flags verified"
    fi

    sandbox_help="$(codex exec --help 2>&1)"
    if grep -q "workspace-write" <<< "${sandbox_help}"; then
        ok "Codex sandbox mode workspace-write available"
    else
        fail "Codex sandbox mode workspace-write not found in --help"
        errors=$((errors + 1))
    fi
else
    fail "codex not found — install with: npm i -g @openai/codex"
    errors=$((errors + 1))
fi

info "Checking Praxis binary"
PRAXIS="$(resolve_praxis_bin)"
if [[ -n "${PRAXIS}" && -x "${PRAXIS}" ]]; then
    ok "Praxis binary found"
else
    fail "Praxis binary not found. Set PRAXIS_BIN or add praxis to PATH."
    errors=$((errors + 1))
fi

info "Checking environment variables"
if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    ok "OPENAI_API_KEY is set (value hidden)"
else
    fail "OPENAI_API_KEY is not set"
    errors=$((errors + 1))
fi

if [[ -n "${OPENAI_MODEL:-}" ]]; then
    ok "OPENAI_MODEL=${OPENAI_MODEL}"
else
    fail "OPENAI_MODEL is not set"
    errors=$((errors + 1))
fi

info "Checking port ${PRAXIS_PORT}"
if port_in_use "${PRAXIS_PORT}"; then
    fail "Port ${PRAXIS_PORT} is already in use"
    errors=$((errors + 1))
else
    ok "Port ${PRAXIS_PORT} is available"
fi

if [[ ${errors} -gt 0 ]]; then
    die "${errors} prerequisite(s) failed"
fi

ok "All prerequisites satisfied"
