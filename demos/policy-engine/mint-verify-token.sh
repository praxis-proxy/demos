#!/usr/bin/env bash
# Mint an access token for a demo persona by hitting IBM Verify
# direct password-grant endpoint. Echoes the raw JWT on stdout.
#
# Usage:
#   ./mint-verify-token.sh alice       # prints alice's user token
#   ./mint-verify-token.sh hr-copilot  # prints the hr-copilot client's
#                                      # service-account token (used as
#                                      # the gateway-Authorization)
#
# Personas:
#   alice    — engineer, role=engineer,  perms=[tool_execute]
#   bob      — HR, role=hr, perms=[tool_execute, view_ssn, pii_access, email_send]
#   charlie  — auditor, role=auditor, perms=[tool_execute, pii_access]
#   eve      — HR, role=hr, perms=[tool_execute]   (NO view_ssn)
#
# Requires `jq`.  

set -euo pipefail
post_deploy_variables="post_deploy_variables.json"
TOKEN_ENDPOINT=$(jq -r '.variables.IBM_VERIFY_TOKEN_ENDPOINT' "$post_deploy_variables")

CLIENT_ID=$(jq -r '.variables.HR_COPILOT_CLIENT_ID' "$post_deploy_variables")
CLIENT_SECRET=$(jq -r '.variables.HR_COPILOT_CLIENT_SECRET' "$post_deploy_variables")

persona="${1:?usage: $0 <alice|bob|charlie|eve|hr-copilot>}"
persona_pw=""
case "$persona" in alice|bob|charlie|eve)
   persona_pw=$(jq -r ".variables.${1}_pw" "$post_deploy_variables")
   ;;
esac

case "$persona" in
  alice|bob|charlie|eve)
    response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password" \
      -d "client_id=$CLIENT_ID" \
      -d "client_secret=$CLIENT_SECRET" \
      -d "username=$persona" \
      -d "password=$persona_pw" \
      -d "scope=openid")
    ;;
  hr-copilot)
    # Service-account / client_credentials grant — for the
    # Authorization header (the client's own identity).
    response=$(curl -s -X POST "$TOKEN_ENDPOINT" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=client_credentials" \
      -d "client_id=$CLIENT_ID" \
      -d "client_secret=$CLIENT_SECRET" \
      -d "scope=openid")
    ;;
  *)
    echo "unknown persona: $persona" >&2
    echo "valid: alice bob charlie eve hr-copilot" >&2
    exit 1
    ;;
esac

if ! token=$(echo "$response" | jq -er '.access_token'); then
  echo "ERROR: IBM Verify did not return an access_token" >&2
  echo "$response" | jq . >&2 || echo "$response" >&2
  exit 1
fi

echo "$token"
