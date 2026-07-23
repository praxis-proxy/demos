#!/usr/bin/env bash
# Stop services and remove all cloned repos, venvs, and artifacts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Stop first
"${SCRIPT_DIR}/stop-demo.sh" 2>/dev/null || true

info "Removing virtual environments..."
rm -rf "${CLIENT_VENV}"

info "Removing cloned repositories..."
rm -rf "${TMP_DIR}"

info "Removing artifacts..."
rm -rf "${ARTIFACTS_DIR}"

info "Removing logs..."
rm -f "${STORE_LOG}" "${WORKER_LOG}" "${PRAXIS_LOG}"

ok "Complete purge finished"
