#!/usr/bin/env bash
# Skillberry Agent Proxy — full automated demo (all services on host).
#
# Usage:
#   export SPAPRAXIS_API_KEY="<your-key>"
#   export SPAPRAXIS_LITELLMPROXY="<host:port>"
#   ./scripts/run-demo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

# Defaults for optional vars
export SPAPRAXIS_MODEL="${SPAPRAXIS_MODEL:-aws/gpt-oss-120b}"
export SPAPRAXIS_TEMPERATURE="${SPAPRAXIS_TEMPERATURE:-0.0}"
export SKILL_NAME="${SKILL_NAME:-praxis-demo-hello-world}"
export SKILL_UUID="${SKILL_UUID:-}"
export ENABLE_THINK_LOGS="${ENABLE_THINK_LOGS:-false}"
export USE_AGENT_TOOLS="${USE_AGENT_TOOLS:-false}"
export USE_AGENT_PROMPTS="${USE_AGENT_PROMPTS:-true}"
export MCP_PROMPTS_POSITION="${MCP_PROMPTS_POSITION:-postfix}"
export REACT_RECURSION_LIMIT="${REACT_RECURSION_LIMIT:-20}"
export SKILLBERRY_STORE_URL="${SKILLBERRY_STORE_URL:-http://127.0.0.1:8000}"

banner

# ══════════════════════════════════════════════════════════════════════════════
section "1/7 Preflight"
cat <<'DESC'
  Checking: python, praxis binary, required env vars, port availability.
DESC

errors=0

for cmd in curl jq envsubst git "${PYTHON_VERSION}"; do
    if command -v "${cmd}" &>/dev/null; then
        ok "${cmd}"
    else
        fail "Required command not found: ${cmd}"
        errors=$((errors + 1))
    fi
done

if [[ ! -x "${PRAXIS_BIN}" ]]; then
    fail "Praxis binary not found at ${PRAXIS_BIN}"
    fail "  Build: cd ~/praxis && cargo build --package praxis-proxy"
    fail "  Or set PRAXIS_BIN= or PRAXIS_ROOT="
    errors=$((errors + 1))
else
    ok "praxis: ${PRAXIS_BIN}"
fi

if [[ -z "${SPAPRAXIS_API_KEY:-}" ]]; then
    fail "SPAPRAXIS_API_KEY is not set"; errors=$((errors + 1))
else
    ok "SPAPRAXIS_API_KEY is set"
fi

if [[ -z "${SPAPRAXIS_LITELLMPROXY:-}" ]]; then
    fail "SPAPRAXIS_LITELLMPROXY is not set (host:port)"; errors=$((errors + 1))
else
    ok "SPAPRAXIS_LITELLMPROXY=${SPAPRAXIS_LITELLMPROXY}"
fi

for p in "${PRAXIS_PORT}" "${STORE_PORT}" "${WORKER_PORT}"; do
    if port_in_use "${p}"; then
        fail "Port ${p} is already in use"
        errors=$((errors + 1))
    else
        ok "Port ${p} is free"
    fi
done

[[ ${errors} -gt 0 ]] && die "Preflight failed with ${errors} error(s)"
ok "All preflight checks passed"

# ══════════════════════════════════════════════════════════════════════════════
section "2/7 Install Dependencies"
cat <<'DESC'
  Cloning repos (if needed) and installing into a local .venv.
DESC

mkdir -p "${TMP_DIR}"

# Clone store
if [[ -d "${STORE_DIR}" ]]; then
    info "skillberry-store already cloned"
else
    info "Cloning skillberry-store..."
    git clone --branch "${STORE_BRANCH}" "${STORE_REPO}" "${STORE_DIR}"
fi

# Clone worker
if [[ -d "${WORKER_DIR}" ]]; then
    info "skillberry-agent-praxis-poc already cloned"
else
    info "Cloning skillberry-agent-praxis-poc..."
    git clone --branch "${WORKER_BRANCH}" "${WORKER_REPO}" "${WORKER_DIR}"
fi

# Store — create venv, then use its own Makefile (handles uv, torch index, etc.)
if [[ ! -d "${STORE_VENV}" ]]; then
    info "Creating store virtual environment..."
    "${PYTHON_VERSION}" -m venv "${STORE_VENV}"
fi
if [[ ! -f "${STORE_DIR}/.stamps/install-requirements-" ]]; then
    info "Installing skillberry-store (this may take a minute)..."
    VIRTUAL_ENV="${STORE_VENV}" PATH="${STORE_VENV}/bin:${PATH}" make -C "${STORE_DIR}" install-requirements > /dev/null 2>&1
fi

# Worker venv (inside cloned repo)
if [[ ! -d "${WORKER_VENV}" ]]; then
    info "Creating worker virtual environment..."
    "${PYTHON_VERSION}" -m venv "${WORKER_VENV}"
    "${WORKER_VENV}/bin/pip" install --quiet --upgrade pip
    info "Installing worker..."
    "${WORKER_VENV}/bin/pip" install --quiet -e "${WORKER_DIR}/worker/"
fi

# Client venv (lightweight — just litellm)
if [[ ! -d "${CLIENT_VENV}" ]]; then
    info "Creating client virtual environment..."
    "${PYTHON_VERSION}" -m venv "${CLIENT_VENV}"
    "${CLIENT_VENV}/bin/pip" install --quiet --upgrade pip
fi
if ! "${CLIENT_VENV}/bin/python" -c "import litellm" 2>/dev/null; then
    info "Installing litellm (for client)..."
    "${CLIENT_VENV}/bin/pip" install --quiet litellm
fi

ok "All dependencies installed"

# ══════════════════════════════════════════════════════════════════════════════
section "3/7 Start Store"
cat <<'DESC'
  Starting Skillberry Store on port 8000.
  Log: /tmp/skillberry-store.log
DESC

VIRTUAL_ENV="${STORE_VENV}" PATH="${STORE_VENV}/bin:${PATH}" EXECUTE_PYTHON_LOCALLY=True make -C "${STORE_DIR}" run > /dev/null 2>&1 &
echo $! > "${STORE_PID_FILE}"
info "Store PID: $(cat "${STORE_PID_FILE}")"
info "Store log: ${STORE_DIR}/service.log"

wait_for_health "http://localhost:${STORE_PORT}/health" "Skillberry Store" 60

# ══════════════════════════════════════════════════════════════════════════════
section "4/7 Import Skill"
cat <<'DESC'
  Importing praxis-demo-hello-world into the store.
  Tools: praxis_demo_greet, praxis_demo_echo.
DESC

SKILL_DIR="${DEMO_DIR}/skills/praxis-demo-hello-world"

if curl -sf "http://localhost:${STORE_PORT}/skills/praxis-demo-hello-world" >/dev/null 2>&1; then
    info "Skill 'praxis-demo-hello-world' already exists — skipping import"
else
    curl -sf -X POST "http://localhost:${STORE_PORT}/skills/import-anthropic" \
        -F "source_type=folder" \
        -F "folder_path=${SKILL_DIR}" \
        -F "snippet_mode=file" | jq .
fi

ok "Skill ready"

# ══════════════════════════════════════════════════════════════════════════════
section "5/7 Start Worker"
cat <<'DESC'
  Starting Skillberry Worker (ReAct agent loop) on port 7010.
  Log: /tmp/worker.log
DESC

LLM_BASE_URL="http://127.0.0.1:8081/v1" \
    "${WORKER_VENV}/bin/uvicorn" worker.main:app --app-dir "${WORKER_DIR}" --host 127.0.0.1 --port "${WORKER_PORT}" \
    > "${WORKER_LOG}" 2>&1 &
echo $! > "${WORKER_PID_FILE}"
info "Worker PID: $(cat "${WORKER_PID_FILE}")"

wait_for_health "http://localhost:${WORKER_PORT}/health" "Skillberry Worker" 30

# ══════════════════════════════════════════════════════════════════════════════
section "6/7 Start Praxis"
cat <<'DESC'
  Starting Praxis on the host.
  - Port 7000: client ingress (injects skill config → worker)
  - Port 8081: LLM egress (credential injection → LiteLLM proxy)
  Log: /tmp/praxis.log
DESC

mkdir -p "${ARTIFACTS_DIR}"

# Derive upstream hostname and detect TLS
export SPAPRAXIS_LITELLMPROXY_HOST="${SPAPRAXIS_LITELLMPROXY%%:*}"
LITELLM_PORT="${SPAPRAXIS_LITELLMPROXY##*:}"

info "Expanding praxis.yaml.tmpl..."
envsubst < "${TEMPLATE}" > "${RUNTIME_CONFIG}"

if [[ "${LITELLM_PORT}" != "443" ]]; then
    sed -i'' -e '/# __TLS_BEGIN__/,/# __TLS_END__/d' "${RUNTIME_CONFIG}"
    info "Plain HTTP upstream (port ${LITELLM_PORT})"
else
    sed -i'' -e '/# __TLS_BEGIN__/d; /# __TLS_END__/d' "${RUNTIME_CONFIG}"
    info "HTTPS upstream (TLS enabled)"
fi

RUST_LOG="${RUST_LOG:-praxis_filter=info}" "${PRAXIS_BIN}" --config "${RUNTIME_CONFIG}" \
    > "${PRAXIS_LOG}" 2>&1 &
echo $! > "${PRAXIS_PID_FILE}"
info "Praxis PID: $(cat "${PRAXIS_PID_FILE}")"

wait_for_health "http://localhost:${PRAXIS_PORT}/health" "Praxis" 15

# ══════════════════════════════════════════════════════════════════════════════
section "7/7 Run Client"
cat <<'DESC'
  Sending a chat completion through the full pipeline:
  Client → Praxis (7000) → Worker (7010) → Praxis LLM-egress (8081) → LiteLLM
DESC

export OPENAI_API_BASE="http://localhost:${PRAXIS_PORT}/v1"
export OPENAI_API_KEY="not-used"

"${CLIENT_VENV}/bin/python" "${SCRIPT_DIR}/emulate_client.py"

# ══════════════════════════════════════════════════════════════════════════════
printf '\n\033[1;32m'
cat <<DONE
  ┌──────────────────────────────────────────────────────────┐
  │          Demo completed successfully!                     │
  │                                                          │
  │   Store:   PID $(cat "${STORE_PID_FILE}")  :${STORE_PORT}  ${STORE_LOG}   │
  │   Worker:  PID $(cat "${WORKER_PID_FILE}")  :${WORKER_PORT}  ${WORKER_LOG}      │
  │   Praxis:  PID $(cat "${PRAXIS_PID_FILE}")  :${PRAXIS_PORT}  ${PRAXIS_LOG}     │
  │                                                          │
  │   Stop:    ./scripts/stop-demo.sh                        │
  │   Purge:   ./scripts/purge-demo.sh                       │
  └──────────────────────────────────────────────────────────┘
DONE
printf '\033[0m\n'
