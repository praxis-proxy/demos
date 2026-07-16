#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env
ensure_artifacts

PRAXIS="$(resolve_praxis_bin)"
[[ -n "${PRAXIS}" && -x "${PRAXIS}" ]] || die "Praxis binary not found. Set PRAXIS_BIN or add praxis to PATH."

if [[ -f "${PID_FILE}" ]]; then
    old_pid="$(cat "${PID_FILE}")"
    if pid_is_praxis "${old_pid}"; then
        die "Praxis is already running (PID ${old_pid}). Use stop-praxis.sh first."
    fi
    rm -f "${PID_FILE}"
fi

if port_in_use "${PRAXIS_PORT}"; then
    die "Port ${PRAXIS_PORT} is occupied by another process."
fi

[[ -n "${OPENAI_MODEL:-}" ]]       || die "OPENAI_MODEL is not set. Cannot render configuration."
[[ -n "${CODEX_CLIENT_MODEL:-}" ]] || die "CODEX_CLIENT_MODEL is not set. Cannot render configuration."

info "Rendering $(relpath "${TEMPLATE}") → $(relpath "${RUNTIME_CONFIG}")"
export PRAXIS_PORT OPENAI_MODEL CODEX_CLIENT_MODEL
envsubst '${PRAXIS_PORT} ${OPENAI_MODEL} ${CODEX_CLIENT_MODEL}' \
    < "${TEMPLATE}" > "${RUNTIME_CONFIG}"

info "Starting Praxis on 127.0.0.1:${PRAXIS_PORT} (PID $$)"
printf '%d' "$$" > "${PID_FILE}"

: > "${LOG_FILE}"
exec > >(tee -a "${LOG_FILE}") 2>&1
exec env RUST_LOG="${RUST_LOG:-praxis_filter=debug,praxis=info}" \
    "${PRAXIS}" -c "${RUNTIME_CONFIG}"
