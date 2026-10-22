#!/usr/bin/env bash
#
# Print an IBM Verify access token for alice, bob, charlie, eve, or hr-copilot.
# Usage: ./mint-verify-token.sh <persona>
# Uses password grant for people and client_credentials for hr-copilot.
# Requires curl, jq, and post_deploy_variables.json.

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
