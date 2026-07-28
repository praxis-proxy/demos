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
section "1/9 Preflight"
cat <<'DESC'
  Checking: python, praxis binary, required env vars, port availability.
DESC

errors=0

for cmd in curl jq envsubst git tmux "${PYTHON_VERSION}"; do
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
section "2/9 Install Dependencies"
cat <<'DESC'
  Cloning repos (if needed) and installing into a local .venv.
DESC

mkdir -p "${TMP_DIR}"

# Clone store (pinned to a release tag)
if [[ -d "${STORE_DIR}" ]]; then
    info "skillberry-store already cloned"
else
    info "Cloning skillberry-store (tag ${STORE_TAG})..."
    git clone --branch "${STORE_TAG}" --depth 1 "${STORE_REPO}" "${STORE_DIR}"
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
section "3/9 Start Store"
cat <<'DESC'
  Starting Skillberry Store on port 8000.
DESC

VIRTUAL_ENV="${STORE_VENV}" PATH="${STORE_VENV}/bin:${PATH}" EXECUTE_PYTHON_LOCALLY=True make -C "${STORE_DIR}" run > /dev/null 2>&1 &
echo $! > "${STORE_PID_FILE}"
info "Store PID: $(cat "${STORE_PID_FILE}")"
info "Store log: ${STORE_LOG}"

wait_for_health "http://localhost:${STORE_PORT}/health" "Skillberry Store" 60

# ══════════════════════════════════════════════════════════════════════════════
section "4/9 Import Skill"
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
section "5/9 Start tmux"
cat <<'DESC'
  Creating tmux session "skillberry-demo" with windows: praxis, worker, client.
DESC

tmux kill-session -t "${TMUX_SESSION}" 2>/dev/null || true
tmux new-session -d -s "${TMUX_SESSION}" -n praxis
tmux set-option -t "${TMUX_SESSION}" status-left ""
tmux new-window -t "${TMUX_SESSION}" -n worker
tmux new-window -t "${TMUX_SESSION}" -n client

ok "tmux session '${TMUX_SESSION}' created"

# ══════════════════════════════════════════════════════════════════════════════
section "6/9 Start Praxis"
cat <<'DESC'
  Starting Praxis gateway.
  - Port 7000: client ingress (injects skill config)
  - Port 8081: LLM egress (credential injection)
DESC

mkdir -p "${ARTIFACTS_DIR}"

# Derive upstream hostname and detect TLS
export SPAPRAXIS_LITELLMPROXY_HOST="${SPAPRAXIS_LITELLMPROXY%%:*}"
LITELLM_PORT="${SPAPRAXIS_LITELLMPROXY##*:}"

info "Expanding praxis.yaml.tmpl..."
envsubst < "${TEMPLATE}" > "${RUNTIME_CONFIG}"

if [[ "${LITELLM_PORT}" != "443" ]]; then
    sed '/# __TLS_BEGIN__/,/# __TLS_END__/d' "${RUNTIME_CONFIG}" > "${RUNTIME_CONFIG}.tmp" && mv "${RUNTIME_CONFIG}.tmp" "${RUNTIME_CONFIG}"
    info "Plain HTTP upstream (port ${LITELLM_PORT})"
else
    sed '/# __TLS_BEGIN__/d; /# __TLS_END__/d' "${RUNTIME_CONFIG}" > "${RUNTIME_CONFIG}.tmp" && mv "${RUNTIME_CONFIG}.tmp" "${RUNTIME_CONFIG}"
    info "HTTPS upstream (TLS enabled)"
fi

# Start praxis in its tmux window
tmux send-keys -t "${TMUX_SESSION}:praxis" \
    "RUST_LOG=${RUST_LOG:-praxis_filter=info} ${PRAXIS_BIN} --config ${RUNTIME_CONFIG}" Enter

# ══════════════════════════════════════════════════════════════════════════════
section "7/9 Start Worker"
cat <<'DESC'
  Starting Skillberry Worker (ReAct agent loop) on port 7010.
DESC

tmux send-keys -t "${TMUX_SESSION}:worker" \
    "LLM_BASE_URL=http://127.0.0.1:8081/v1 ${WORKER_VENV}/bin/uvicorn worker.main:app --app-dir ${WORKER_DIR} --host 127.0.0.1 --port ${WORKER_PORT}" Enter

wait_for_health "http://localhost:${WORKER_PORT}/health" "Skillberry Worker" 30

# ══════════════════════════════════════════════════════════════════════════════
section "8/9 Browse Skill"
cat <<'DESC'
  Querying the imported skill from the Skillberry Store API.
DESC

info "curl -s http://localhost:${STORE_PORT}/skills/praxis-demo-hello-world?fields=full | jq ..."
printf '\n'
curl -s "http://localhost:${STORE_PORT}/skills/praxis-demo-hello-world?fields=full" | jq '{tools: [.tools[] | {name, description}], snippets: [.snippets[] | {name, content}]}'
printf '\n'

printf '  Press any key to continue...'
read -r -n 1 -s
printf '\n'

# ══════════════════════════════════════════════════════════════════════════════
section "9/9 Run Client"

printf '\n\033[1;32m'
printf '  ┌──────────────────────────────────────────────────────────────┐\n'
printf '  │          Demo initiated successfully!                        │\n'
printf '  │                                                              │\n'
printf '  │   tmux session: %-45s│\n' "${TMUX_SESSION} (created)"
printf '  │                                                              │\n'
printf '  │   Windows:                                                   │\n'
printf '  │     praxis  - Praxis gateway on :%-28s│\n' "${PRAXIS_PORT}"
printf '  │     worker  - Skillberry Worker on :%-25s│\n' "${WORKER_PORT}"
printf '  │     client  - Chat client                                    │\n'
printf '  │                                                              │\n'
printf '  │   Attach:  tmux attach -t %-35s│\n' "${TMUX_SESSION}"
printf '  │   Detach:  Ctrl-b d                                          │\n'
printf '  │   Switch:  Ctrl-b n (next window)                            │\n'
printf '  │   Stop:    ./scripts/stop-demo.sh                            │\n'
printf '  │   Purge:   ./scripts/purge-demo.sh                           │\n'
printf '  └──────────────────────────────────────────────────────────────┘\n'
printf '\033[0m\n'

printf '  Press any key to run the client... (scripts/emulate_client.py)'
read -r -n 1 -s
printf '\n\n'

info "Sending request through the full pipeline (Praxis → Worker → Store → LLM)..."
printf '\n'
OPENAI_API_BASE="http://localhost:${PRAXIS_PORT}/v1" OPENAI_API_KEY=not-used \
    "${CLIENT_VENV}/bin/python" "${SCRIPT_DIR}/emulate_client.py"
printf '\n'

# Also send to tmux client window for later reference
tmux send-keys -t "${TMUX_SESSION}:client" \
    "OPENAI_API_BASE=http://localhost:${PRAXIS_PORT}/v1 OPENAI_API_KEY=not-used ${CLIENT_VENV}/bin/python ${SCRIPT_DIR}/emulate_client.py" Enter

printf '\n  Press any key to attach to tmux session...'
read -r -n 1 -s
printf '\n'

exec tmux attach -t "${TMUX_SESSION}"
