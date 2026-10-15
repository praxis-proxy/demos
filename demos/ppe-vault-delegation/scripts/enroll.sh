#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

subject="${1:-alice}"
source_mode="${2:-prompt}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-demo-root}"
GITHUB_API_BASE="${GITHUB_API_BASE:-https://api.github.com}"
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$subject" in
  alice|bob) ;;
  *) echo "subject must be alice or bob" >&2; exit 2 ;;
esac

case "$source_mode" in
  --from-gh)
    command -v gh >/dev/null || { echo "gh is required for --from-gh" >&2; exit 1; }
    token="$(gh auth token)"
    ;;
  --stdin)
    IFS= read -r token || [ -n "$token" ]
    ;;
  prompt)
    read -r -s -p "GitHub token for $subject: " token
    printf '\n' >&2
    ;;
  *) echo "usage: enroll.sh [alice|bob] [--from-gh|--stdin]" >&2; exit 2 ;;
esac

[ -n "$token" ] || { echo "empty GitHub token" >&2; exit 1; }

mkdir -p "$DEMO_DIR/.state"
chmod 700 "$DEMO_DIR/.state"

expected_login="$(
  printf '%s' "$token" \
    | GITHUB_API_BASE="$GITHUB_API_BASE" python3 "$DEMO_DIR/scripts/github-login.py"
)"

response="$(
  printf '%s' "$token" \
    | jq -Rs '{data:{token:.}}' \
    | curl -fsS -X PUT \
        -H "X-Vault-Token: $VAULT_TOKEN" \
        -H "content-type: application/json" \
        --data-binary @- \
        "$VAULT_ADDR/v1/secret/data/agents/$subject/github"
)"
unset token

version="$(printf '%s' "$response" | jq -er '.data.version')"
printf '%s\n' "$expected_login" >"$DEMO_DIR/.state/$subject.expected-github-login"
chmod 600 "$DEMO_DIR/.state/$subject.expected-github-login"
printf 'enrolled GitHub credential for %s (Vault version %s)\n' "$subject" "$version"
