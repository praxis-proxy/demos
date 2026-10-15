#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-demo-root}"
public_key="$DEMO_DIR/.state/demo-public.pem"

[ -s "$public_key" ] || { echo "missing demo public key" >&2; exit 1; }

vault_request() {
  method="$1"
  path="$2"
  curl -fsS -X "$method" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "content-type: application/json" \
    --data-binary @- \
    "$VAULT_ADDR/v1/$path"
}

if ! curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/auth" \
  | jq -e '.data["jwt/"]' >/dev/null; then
  printf '%s' '{"type":"jwt"}' | vault_request POST sys/auth/jwt >/dev/null
fi

jq -n \
  --rawfile public_key "$public_key" \
  '{jwt_validation_pubkeys:[$public_key],bound_issuer:"https://ppe-vault-demo.local"}' \
  | vault_request POST auth/jwt/config >/dev/null

accessor="$(
  curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/auth" \
    | jq -er '.data["jwt/"].accessor'
)"

printf 'path "secret/data/agents/{{identity.entity.aliases.%s.name}}/*" {\n  capabilities = ["read"]\n}\n' "$accessor" \
  | jq -Rs '{policy:.}' \
  | vault_request PUT sys/policies/acl/ppe-user >/dev/null

jq -n '{
  role_type:"jwt",
  user_claim:"sub",
  bound_audiences:["vault-demo"],
  token_policies:["ppe-user"],
  token_ttl:"5m",
  token_max_ttl:"5m"
}' | vault_request POST auth/jwt/role/ppe-user >/dev/null

# Audit requests to container stdout so the early-deny scenario can prove it
# did not contact Vault. This is demo observability, not durable audit storage.
if ! curl -fsS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/audit" \
  | jq -e '.data["demo/"]' >/dev/null; then
  printf '%s' '{"type":"file","options":{"file_path":"stdout"}}' \
    | vault_request PUT sys/audit/demo >/dev/null
fi

echo "Vault JWT auth and per-user KV policy configured"
