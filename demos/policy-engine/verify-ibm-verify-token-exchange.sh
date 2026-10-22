#!/usr/bin/env bash
#
# Check RFC 8693 token exchange against IBM Verify.
# Usage: ./verify-ibm-verify-token-exchange.sh
# Reads minting and exchange credentials from post_deploy_variables.json.
# See verify/README.md for tenant provisioning and required entitlements.

set -euo pipefail
post_deploy_variables="post_deploy_variables.json"

TOKEN_ENDPOINT=$(jq -r '.variables.IBM_VERIFY_TOKEN_ENDPOINT' "$post_deploy_variables")


USER_CLIENT_ID=$(jq -r '.variables.HR_COPILOT_CLIENT_ID' "$post_deploy_variables")
USER_CLIENT_SECRET=$(jq -r '.variables.HR_COPILOT_CLIENT_SECRET' "$post_deploy_variables")

GATEWAY_CLIENT_ID=$(jq -r '.variables.GATEWAY_CLIENT_ID' "$post_deploy_variables")
GATEWAY_CLIENT_SECRET=$(jq -r '.variables.GATEWAY_CLIENT_SECRET' "$post_deploy_variables")

AUDIENCE="workday-api"
persona="alice"
persona_pw=""
case "$persona" in alice|bob|charlie|eve)
   persona_pw="${persona}Lab3151"
   ;;
esac


red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

ok()   { printf "  %s %-32s %s\n" "$(green ✓)" "$1" "$2"; }
fail() { printf "  %s %-32s %s\n" "$(red ✗)" "$1" "$2"; }

# 1. Mint alice's user token via password grant.
alice_resp=$(curl -s -X POST "$TOKEN_ENDPOINT" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=$USER_CLIENT_ID" \
  -d "client_secret=$USER_CLIENT_SECRET" \
  -d "username=alice" \
  -d "password=$persona_pw" \
  -d "scope=openid")

alice_token=$(echo "$alice_resp" | jq -r '.access_token // empty')
if [ -z "$alice_token" ]; then
  fail "alice mint" "(see error below)"
  echo "$alice_resp" | jq . >&2 || echo "$alice_resp" >&2
  exit 1
fi
ok "alice mint" "OK"

# 2. Exchange alice's token for workday-api audience as the
#    praxis-gateway client. This is exactly the call the
#    OAuthDelegator makes from inside the gateway.
exchange_resp=$(curl -s -X POST "$TOKEN_ENDPOINT" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -u "${GATEWAY_CLIENT_ID}:${GATEWAY_CLIENT_SECRET}" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "subject_token=$alice_token" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "audience=$AUDIENCE" \
  -d "purpose=P4AUD")

minted=$(echo "$exchange_resp" | jq -r '.access_token // empty')
if [ -z "$minted" ]; then
  err=$(echo "$exchange_resp" | jq -r '.error // empty')
  desc=$(echo "$exchange_resp" | jq -r '.error_description // empty')
  fail "praxis-gateway → workday-api" "${err}: ${desc}"
  echo
  echo "$(dim 'Full IBM Verify response:')"
  echo "$exchange_resp" | jq . >&2 || echo "$exchange_resp" >&2
  echo
  echo "$(dim 'Common causes:')"
  echo "$(dim '  - token-exchange feature not enabled in the running')"
  echo "$(dim '    IBM Verify instance')"
  exit 1
fi

# Decode the minted token's payload (middle JWT segment, base64url).
payload=$(echo "$minted" | awk -F. '{print $2}')
# pad the base64 to a multiple of 4
case $((${#payload} % 4)) in
  2) payload="${payload}==" ;;
  3) payload="${payload}=" ;;
esac
decoded=$(printf "%s" "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null || true)
# `aud` may be a single string or an array (RFC 7519 §4.1.3). When it's an
# array, pull out the entry matching $AUDIENCE so the check below passes
# regardless of its position; fall back to the first entry when absent so the
# mismatch message shows something useful.
aud=$(echo "$decoded" | jq -r --arg want "$AUDIENCE" '
  if (.aud | type) == "array" then
    (.aud | index($want) as $i | if $i then .[$i] else (.[0] // "?") end)
  else
    (.aud // "?")
  end' 2>/dev/null || echo "?")
sub=$(echo "$decoded" | jq -r '.sub // "?"' 2>/dev/null || echo "?")

if [ "$aud" = "$AUDIENCE" ]; then
  ok "praxis-gateway → workday-api" "OK (aud=$aud)"
else
  fail "praxis-gateway → workday-api" "aud mismatch: expected '$AUDIENCE' got '$aud'"
  echo "$alice_token" | awk -F. '{print $2"=="}' | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
  echo "$decoded" | jq .
  exit 1
fi

echo
echo "$(dim 'minted token aud claim:') $aud"
echo "$(dim 'minted token sub claim:') $sub"
echo
echo "$(green 'Token exchange works.') The OAuthDelegator inside the gateway will use the same call shape during the demo scenarios."
# echo "$alice_token" | awk -F. '{print $2"=="}' | tr '_-' '/+' | base64 -d 2>/dev/null | jq .
# echo "$decoded" | jq .

