#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"
load_env
ensure_artifacts

[[ -n "${OPENAI_API_KEY:-}" ]] || die "OPENAI_API_KEY is not set"
[[ -n "${OPENAI_MODEL:-}" ]]  || die "OPENAI_MODEL is not set"

PRAXIS="$(praxis_url)"
WORKSPACE="${ARTIFACTS_DIR}/codex-workspace"
CODEX_JSONL="${ARTIFACTS_DIR}/codex.jsonl"
CODEX_STDERR="${ARTIFACTS_DIR}/codex.stderr.log"
PROOF_FILE="${WORKSPACE}/proof.txt"
EXPECTED_CONTENT="praxis-openai-codex-e2e"

SANDBOX_MODE="${CODEX_SANDBOX_MODE:-workspace-write}"
if [[ "${SANDBOX_MODE}" == "danger-full-access" ]]; then
    info "WARNING: sandbox mode overridden to danger-full-access by CODEX_SANDBOX_MODE"
fi

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}"

info "Codex workspace: $(relpath "${WORKSPACE}")"
info "Custom provider → ${PRAXIS} (wire_api=responses)"
info "Client model: ${CODEX_CLIENT_MODEL}"

codex exec \
    --ignore-user-config \
    --ignore-rules \
    --skip-git-repo-check \
    --ephemeral \
    --json \
    -C "${WORKSPACE}" \
    -s "${SANDBOX_MODE}" \
    -m "${CODEX_CLIENT_MODEL}" \
    -c "model_provider=\"praxis-demo\"" \
    -c "model_providers.praxis-demo.name=\"Praxis OpenAI passthrough\"" \
    -c "model_providers.praxis-demo.base_url=\"${PRAXIS}/v1\"" \
    -c "model_providers.praxis-demo.wire_api=\"responses\"" \
    -c "model_providers.praxis-demo.env_key=\"OPENAI_API_KEY\"" \
    "Create a file called proof.txt containing exactly the text: ${EXPECTED_CONTENT} — then read it back and confirm the content matches." \
    > "${CODEX_JSONL}" \
    2> "${CODEX_STDERR}" \
    || {
        fail "Codex exited with non-zero status"
        info "stderr tail:"
        tail -20 "${CODEX_STDERR}" >&2
        exit 1
    }

ok "Codex completed successfully"

proof_ok=true
if [[ -f "${PROOF_FILE}" ]]; then
    content="$(cat "${PROOF_FILE}")"
    if [[ "${content}" == "${EXPECTED_CONTENT}" ]]; then
        ok "Proof file verified: $(relpath "${PROOF_FILE}")"
    else
        fail "Proof file content mismatch: expected '${EXPECTED_CONTENT}', got '${content}'"
        proof_ok=false
    fi
else
    fail "Proof file not found: ${PROOF_FILE}"
    proof_ok=false
fi

info "JSONL log: $(relpath "${CODEX_JSONL}") ($(wc -l < "${CODEX_JSONL}") lines)"
info "Stderr log: $(relpath "${CODEX_STDERR}")"

[[ "${proof_ok}" == "true" ]] || exit 1
