#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# PROBE (gateway-free): does live Keycloak accept an agent's SVID as the RFC 8693
# `actor_token` in a token exchange, and emit an `act` claim? This is the one path
# behind cookbook Recipe 6 (subject: user, actor: caller_workload — the dual-principal
# case) that PPE has only *mock*-tested. Run this before wiring a demo scenario for
# it: the result decides whether Recipe 6 works as pure config or needs delegator work.
#
# It tries TWO shapes for the actor credential and reports which (if either) Keycloak
# accepts:
#   A. actor_token = the RAW SVID          <- exactly what the PPE delegator sends today
#   B. actor_token = a base token minted    <- fallback: SVID->client_assertion->token,
#      from the SVID first (scenario-13 leg 1)   then that Keycloak token as the actor
#
# The subject is always the user's token (bob), as in Recipe 1/6.
#
# Prereq: full stack + SPIRE + SPIFFE IdP/client configured:
#   WITH_SPIRE=1 ./restart.sh
#   ./spire/setup-spiffe-idp.sh && ./spire/configure-federated-client.sh
set -euo pipefail

KC="${KC:-http://localhost:8081}"
REALM="${REALM:-policy-demo}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://policy.demo/agent/hr-copilot}"
AUDIENCE="${AUDIENCE:-workday-api}"
SCOPE="${SCOPE:-read_compensation}"
# The user whose authority the minted token speaks for (the subject).
USER_PERSONA="${USER_PERSONA:-bob}"
USER_CLIENT="${USER_CLIENT:-hr-copilot}"
USER_SECRET="${USER_SECRET:-hr-copilot-secret}"
# The gateway client that performs the exchange (STE v2 enabled).
EXCHANGE_CLIENT="${EXCHANGE_CLIENT:-praxis-gateway}"
EXCHANGE_SECRET="${EXCHANGE_SECRET:-praxis-gateway-secret}"
TOKEN_URL="$KC/realms/$REALM/protocol/openid-connect/token"
ISSUER="$KC/realms/$REALM"
JWT_TT="urn:ietf:params:oauth:token-type:jwt"
ACCESS_TT="urn:ietf:params:oauth:token-type:access_token"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.spire.yml)

claims() { # decode a JWT payload and print selected claims (incl. nested act.sub)
  python3 -c '
import sys,json,base64
tok=sys.stdin.read().strip()
p=tok.split(".")[1]; p+="="*(-len(p)%4)
c=json.loads(base64.urlsafe_b64decode(p))
out=[]
for k in sys.argv[1:]:
    if k=="act":
        out.append("act.sub="+str((c.get("act") or {}).get("sub")))
    elif k in c:
        out.append(f"{k}={c[k]}")
print("   " + " | ".join(out))' "$@"
}

# POST a token-exchange and print either the act claim or the KC error.
try_exchange() { # $1=label  $2=subject_token  $3=actor_token  $4=actor_token_type
  local label="$1" subj="$2" act="$3" att="$4"
  echo "-- $label"
  local resp
  resp=$(curl -sS -X POST "$TOKEN_URL" \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d client_id="$EXCHANGE_CLIENT" -d client_secret="$EXCHANGE_SECRET" \
    -d subject_token="$subj" -d subject_token_type="$ACCESS_TT" \
    -d actor_token="$act" -d actor_token_type="$att" \
    -d audience="$AUDIENCE" -d scope="$SCOPE") || true
  local tok
  tok=$(printf '%s' "$resp" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  if [ -n "$tok" ]; then
    printf '%s' "$tok" | claims sub act aud scope
    if printf '%s' "$tok" | claims act | grep -q 'act.sub=None'; then
      echo "   RESULT: exchanged OK but NO act claim (Keycloak dropped the actor)"
      return 2
    fi
    echo "   RESULT: OK — act claim present"
    return 0
  fi
  echo "   RESULT: rejected — $(printf '%s' "$resp" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("error"),"/",d.get("error_description"))' 2>/dev/null || echo "$resp")"
  return 1
}

echo "1. user token (subject) for '$USER_PERSONA'"
USER_TOK=$(curl -sf -X POST "$TOKEN_URL" \
  -d grant_type=password -d client_id="$USER_CLIENT" -d client_secret="$USER_SECRET" \
  -d username="$USER_PERSONA" -d password="$USER_PERSONA" -d scope=openid \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
printf '%s' "$USER_TOK" | claims preferred_username aud

echo "2. agent SVID (the actor), aud=$ISSUER"
SVID=$("${COMPOSE[@]}" exec -T spire-server /opt/spire/bin/spire-server jwt mint \
  -spiffeID "$SPIFFE_ID" -audience "$ISSUER" 2>/dev/null | tr -d '[:space:]')
printf '%s' "$SVID" | claims sub aud

echo "3. Variant A — actor_token = RAW SVID (what the PPE delegator sends today)"
rc_a=0; try_exchange "subject=user, actor=SVID" "$USER_TOK" "$SVID" "$JWT_TT" || rc_a=$?

echo "4. Variant B — actor_token = base token minted from the SVID (fallback)"
BASE=$(curl -sf -X POST "$TOKEN_URL" \
  -d grant_type=client_credentials \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
  -d client_assertion="$SVID" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])' 2>/dev/null || true)
if [ -z "$BASE" ]; then
  echo "-- could not mint the agent base token (client_assertion leg failed); skipping B"
  rc_b=1
else
  rc_b=0; try_exchange "subject=user, actor=base-token" "$USER_TOK" "$BASE" "$ACCESS_TT" || rc_b=$?
fi

echo
echo "=================== VERDICT ==================="
if [ "${rc_a:-1}" -eq 0 ]; then
  echo "Recipe 6 works AS CONFIGURED: Keycloak accepts the raw SVID as actor_token."
  echo "-> add the demo scenario with delegate(subject: user, actor: caller_workload) as-is."
elif [ "${rc_b:-1}" -eq 0 ]; then
  echo "Raw SVID is NOT accepted as actor_token, but a base token minted from it IS."
  echo "-> the actor path needs the same client_assertion leg as scenario 13 before the"
  echo "   exchange (delegator work), not just YAML. Recipe 6's note stands: verify per IdP."
else
  echo "Neither variant produced an act claim on this Keycloak."
  echo "-> expected here: Keycloak 26.8 reads actor_token only with the preview"
  echo "   token-exchange-delegation feature, and then needs may_act in the subject token."
fi
