#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
state="$DEMO_DIR/.state"
subject="${1:?usage: mint-jwt.sh <subject>}"

case "$subject" in
  alice|bob) ;;
  *) echo "subject must be alice or bob" >&2; exit 2 ;;
esac

mkdir -p "$state"
chmod 700 "$state"
umask 077

private_key="$state/demo-private.pem"
public_key="$state/demo-public.pem"
if [ ! -s "$private_key" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$private_key" >/dev/null 2>&1
  openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
elif [ ! -s "$public_key" ]; then
  openssl pkey -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
fi

base64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
expires="$((now + 3600))"
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url)"
payload="$(
  jq -cn \
    --arg iss "https://ppe-vault-demo.local" \
    --arg aud "vault-demo" \
    --arg sub "$subject" \
    --argjson iat "$now" \
    --argjson exp "$expires" \
    '{iss:$iss,aud:$aud,sub:$sub,preferred_username:$sub,roles:["demo-user"],iat:$iat,exp:$exp}' \
    | base64url
)"
unsigned="$header.$payload"
signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$private_key" | base64url)"
printf '%s.%s\n' "$unsigned" "$signature" >"$state/$subject.jwt"
chmod 600 "$state/$subject.jwt"

"$DEMO_DIR/scripts/render-policy.sh"
printf '%s\n' "$state/$subject.jwt"
