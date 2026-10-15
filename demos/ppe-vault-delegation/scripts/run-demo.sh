#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATEWAY_URL="${GATEWAY_URL:-http://127.0.0.1:8090/}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-demo-root}"

expected_login_file="$DEMO_DIR/.state/alice.expected-github-login"
[ -s "$expected_login_file" ] || {
  echo "missing expected GitHub login: run scripts/enroll.sh alice first" >&2
  exit 1
}
expected_login="$(<"$expected_login_file")"

github_token="$(
  curl -fsS \
      -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/secret/data/agents/alice/github" \
    | jq -er '.data.data.token'
)"
[ -n "$github_token" ] || { echo "Vault returned an empty GitHub token" >&2; exit 1; }

assert_token_absent() {
  label="$1"
  content="$2"
  if [[ "$content" == *"$github_token"* ]]; then
    printf 'GitHub token leaked into %s\n' "$label" >&2
    exit 1
  fi
}

call_tool() {
  subject="$1"
  tool="$2"
  token="$(<"$DEMO_DIR/.state/$subject.jwt")"
  jq -cn --arg tool "$tool" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$tool,arguments:{}}}' \
    | curl -fsS \
        -H 'content-type: application/json' \
        -H "X-User-Token: $token" \
        --data-binary @- \
        "$GATEWAY_URL"
}

echo "[1/3] alice: enrolled credential reaches GitHub"
github_before="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
alice_response="$(call_tool alice github_whoami)"
assert_token_absent "Alice response" "$alice_response"
printf '%s\n' "$alice_response" | jq .
actual_login="$(printf '%s' "$alice_response" | jq -er '.result.content[0].text | fromjson | .login')"
[ "$actual_login" = "$expected_login" ] || {
  printf 'expected GitHub login %s, got %s\n' "$expected_login" "$actual_login" >&2
  exit 1
}
github_after="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
[ "$github_after" -eq "$((github_before + 1))" ] || {
  echo "Alice request did not make exactly one GitHub call" >&2
  exit 1
}

echo "[2/3] bob: no enrolled credential"
github_before="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
bob_response="$(call_tool bob github_whoami || true)"
assert_token_absent "Bob response" "$bob_response"
printf '%s\n' "$bob_response" | jq .
printf '%s' "$bob_response" | grep -Fq 'delegation.vault_secret_not_found'
github_after="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
[ "$github_before" = "$github_after" ] || { echo "unenrolled user contacted GitHub" >&2; exit 1; }

echo "[3/3] policy deny: no Vault or GitHub dependency call"
vault_since="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
github_before="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
deny_response="$(call_tool alice github_denied || true)"
assert_token_absent "policy-denied response" "$deny_response"
printf '%s\n' "$deny_response" | jq .
printf '%s' "$deny_response" | grep -Fq 'demo.policy_denied'
vault_requests="$(
  docker compose -f "$DEMO_DIR/docker-compose.yml" logs --no-color --since "$vault_since" vault \
    | awk '/"type":"request"/ { count++ } END { print count + 0 }'
)"
github_after="$(curl -fsS http://127.0.0.1:9100/stats | jq -er '.github_calls')"
[ "$vault_requests" -eq 0 ] || { echo "policy deny contacted Vault" >&2; exit 1; }
[ "$github_before" = "$github_after" ] || { echo "policy deny contacted GitHub" >&2; exit 1; }

echo "[security] token is absent from outputs and local artifacts"
service_logs="$(
  docker compose -f "$DEMO_DIR/docker-compose.yml" logs --no-color 2>&1 || true
)"
assert_token_absent "service logs" "$service_logs"

if ! printf '%s' "$github_token" \
  | python3 "$DEMO_DIR/scripts/assert-token-absent.py" "$DEMO_DIR"; then
  exit 1
fi

unset github_token
echo "demo passed"
