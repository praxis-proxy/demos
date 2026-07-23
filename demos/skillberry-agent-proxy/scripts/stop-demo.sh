#!/usr/bin/env bash
# Stop all services started by run-demo.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

info "Stopping demo services..."

# Kill tmux session (takes down worker, praxis, client)
tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null && ok "tmux session '${TMUX_SESSION}' killed" || true

# Port-based fallback for any remaining processes
stop_pid_file "${PRAXIS_PID_FILE}" "Praxis" "${PRAXIS_PORT}"
stop_pid_file "${WORKER_PID_FILE}" "Worker" "${WORKER_PORT}"
stop_pid_file "${STORE_PID_FILE}" "Store" "${STORE_PORT}"

rm -f "${ARTIFACTS_DIR}/praxis.runtime.yaml" 2>/dev/null || true

ok "All services stopped"
printf '\n'
info "Logs preserved at:"
info "  ${STORE_LOG}"
info "  ${WORKER_LOG}"
info "  ${PRAXIS_LOG}"
