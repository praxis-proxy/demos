#!/usr/bin/env bash
# Generate an RSA keypair, a JWKS document, and the demo's agent JWTs.
#
# The limiter keys on the VERIFIED subject (`subject.id`), which the identity/jwt
# plugin maps from each token's `sub` claim. Each token is a different agent:
#
#   agent-blue.jwt   sub=agent-blue    — one agent, its own request budget
#   agent-green.jwt  sub=agent-green   — another agent, an independent budget
#   nosub.jwt        (no sub)          — valid signature/issuer/audience but NO
#                                        subject, to exercise ratelimit.no_identity
#
# Outputs:
#   jwt/private.pem    RSA 2048-bit private key (git-ignored; never served)
#   jwt/jwks.json      JWKS document (public key; this is what jwt-issuer serves)
#   jwt/tokens/*.jwt   the persona tokens (git-ignored)
#
# Re-running is cheap and idempotent: the key/JWKS are reused if present, tokens
# are always re-minted.
set -euo pipefail
cd "$(dirname "$0")"

JWT_ISSUER="${JWT_ISSUER:-https://jwt-issuer.praxis.local}"
JWT_AUDIENCE="${JWT_AUDIENCE:-ratelimit-agents-requests}"
JWT_KID="${JWT_KID:-ratelimit-demo}"

PRIV_KEY="private.pem"
JWKS_FILE="jwks.json"
TOKENS_DIR="tokens"

# base64url (no padding), reading stdin.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Convert a hex string (stdin) to raw bytes.
_hex_to_bin() {
  local hex escaped
  hex="$(cat)"
  escaped="$(printf '%s' "${hex}" | sed 's/../\\x&/g')"
  printf '%b' "${escaped}"
}

# Generate the RSA keypair if absent.
if [ ! -f "${PRIV_KEY}" ]; then
  echo "Generating RSA keypair..."
  openssl genrsa -out "${PRIV_KEY}" 2048 2>/dev/null
  echo "  Created: ${PRIV_KEY}"
fi

# Generate the JWKS from the private key (refresh if the key is newer).
if [ ! -f "${JWKS_FILE}" ] || [ "${PRIV_KEY}" -nt "${JWKS_FILE}" ]; then
  echo "Generating JWKS..."
  modulus_hex="$(openssl rsa -in "${PRIV_KEY}" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')"
  n="$(printf '%s' "${modulus_hex}" | _hex_to_bin | b64url)"
  cat > "${JWKS_FILE}" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "RS256",
      "kid": "${JWT_KID}",
      "n": "${n}",
      "e": "AQAB"
    }
  ]
}
EOF
  echo "  Created: ${JWKS_FILE}"
fi

# jwt_mint <sub>   — prints a signed RS256 JWT with the given subject.
# jwt_mint ""      — prints a token with NO `sub` claim (for the no-identity case).
jwt_mint() {
  local sub="$1"
  local header payload signing_input sig iat exp
  iat="$(date +%s)"
  exp="$((iat + 315360000))" # +10 years; this is a local test fixture.

  header="$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "${JWT_KID}" | b64url)"
  if [ -n "${sub}" ]; then
    payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${sub}" "${JWT_AUDIENCE}" "${iat}" "${exp}" | b64url)"
  else
    payload="$(printf '{"iss":"%s","aud":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${JWT_AUDIENCE}" "${iat}" "${exp}" | b64url)"
  fi
  signing_input="${header}.${payload}"
  sig="$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${PRIV_KEY}" -binary | b64url)"
  printf '%s.%s' "${signing_input}" "${sig}"
}

echo "Minting agent tokens..."
mkdir -p "${TOKENS_DIR}"
jwt_mint "agent-blue"  > "${TOKENS_DIR}/agent-blue.jwt"
jwt_mint "agent-green" > "${TOKENS_DIR}/agent-green.jwt"
jwt_mint ""            > "${TOKENS_DIR}/nosub.jwt"
echo "  Created: ${TOKENS_DIR}/{agent-blue,agent-green,nosub}.jwt"
echo ""
echo "JWT generation complete."
echo "  JWKS:   jwt/jwks.json  (served by jwt-issuer.py)"
echo "  Tokens: jwt/tokens/{agent-blue,agent-green,nosub}.jwt"
