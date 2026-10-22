#!/usr/bin/env bash
#
# Provision Verify OAuth clients, consent purpose, and optional Agent Registry
# records from clients.csv. Run import-verify-users.sh first.
#
# Usage:
#   ./import-verify-clients.sh [--csv other.csv]
#   ./import-verify-clients.sh --dry-run         # print payloads
#   ./import-verify-clients.sh --discover        # inspect tenant configuration
#   ./import-verify-clients.sh --no-write-back   # leave deployment variables unchanged
#   ./import-verify-clients.sh --all-users       # tenant-wide application entitlement
#   ./import-verify-clients.sh --no-entitle      # preserve managed entitlements
#   ./import-verify-clients.sh --no-purpose      # skip DPCM purpose creation
#   ./import-verify-clients.sh --delete
#
# Requires: curl, jq, python3, and manageAppAccessAdmin on the provisioning client.
# Credentials come from VERIFY_ADMIN_CLIENT_ID/_SECRET in .env.verify; the tenant
# URL comes from post_deploy_variables.json. Generated credentials are saved
# there and in .env.verify. See verify/README.md for setup.
#
# JWT clients require idTokenSigningAlg. Token-exchange clients require
# application entitlement for their subjects.
# 3a. Set subjectTokenTypes and requestedTokenTypes under additionalConfig.
# DPCM exchanges require an active purpose, published before clients
# reference it. --discover reports tenant-specific template and attribute names.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CSV="$SCRIPT_DIR/clients.csv"
DRY_RUN=false
DO_DELETE=false
DISCOVER_ONLY=false
WRITE_BACK=true
# Explicit user grants by default; --all-users selects birthright access.
ALL_USERS=false
DO_ENTITLE=true
# The DPCM purpose the exchange client auto-grants. Created before the clients;
# --no-purpose skips it for a tenant that manages purposes out of band.
DO_PURPOSE=true
# Overridable so a tenant using a different custom-application template can be
# targeted without editing the script; --discover reports what the tenant uses.
TEMPLATE_ID="${VERIFY_APP_TEMPLATE_ID:-998}"
SIGNING_ALG="${VERIFY_ACCESS_TOKEN_SIGNING_ALG:-RS256}"
# DPCM purpose id auto-granted by the exchange client's tokenRequestMap (see
# app_payload). Must match the `purpose=` that
# verify-ibm-verify-token-exchange.sh sends on the exchange call.
CONSENT_PURPOSE_ID="${VERIFY_CONSENT_PURPOSE_ID:-P4AUD}"
# Purpose defaults; --discover reports tenant values.
CONSENT_PURPOSE_NAME="${VERIFY_CONSENT_PURPOSE_NAME:-$CONSENT_PURPOSE_ID}"
CONSENT_PURPOSE_DESC="${VERIFY_CONSENT_PURPOSE_DESC:-support request-scoped aud}"
# Days a granted consent stays valid. 365 is the tenant's value; DPCM requires
# the field, so there is no "unset".
CONSENT_PURPOSE_DURATION="${VERIFY_CONSENT_PURPOSE_DURATION:-365}"
# Pipe-separated, like the CSV's list columns.
CONSENT_PURPOSE_TAGS="${VERIFY_CONSENT_PURPOSE_TAGS:-request|aud|scope}"
# The access type the purpose is consented FOR. DPCM ships "default"; the
# tokenRequestMap does not name one, so the purpose's own default applies.
CONSENT_PURPOSE_ACCESS_TYPE="${VERIFY_CONSENT_PURPOSE_ACCESS_TYPE:-default}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=true ;;
    --discover)      DISCOVER_ONLY=true ;;
    --delete)        DO_DELETE=true ;;
    --no-write-back) WRITE_BACK=false ;;
    --all-users)     ALL_USERS=true ;;
    --no-entitle)    DO_ENTITLE=false ;;
    --no-purpose)    DO_PURPOSE=false ;;
    --csv)           CSV="${2:?--csv needs a path}"; shift ;;
    --template-id)   TEMPLATE_ID="${2:?--template-id needs a value}"; shift ;;
    # Print the usage summary through Requires:.
    -h|--help)       sed -n '2,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow(){ printf '\033[33m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }

ok()   { printf "  %s %-30s %s\n" "$(green ✓)" "$1" "${2:-}"; }
warn() { printf "  %s %-30s %s\n" "$(yellow !)" "$1" "${2:-}"; }
fail() { printf "  %s %-30s %s\n" "$(red ✗)" "$1" "${2:-}"; }

die() { echo "$(red ERROR:) $*" >&2; exit 1; }

for tool in curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not on PATH"
done
[ -f "$CSV" ] || die "client source not found: $CSV"

# --- tenant + credentials -------------------------------------------------
PDV="$DEMO_DIR/post_deploy_variables.json"
[ -f "$PDV" ] || die "post_deploy_variables.json not found at $PDV"

TOKEN_ENDPOINT=$(jq -r '.variables.IBM_VERIFY_TOKEN_ENDPOINT // empty' "$PDV")
[ -n "$TOKEN_ENDPOINT" ] || die "IBM_VERIFY_TOKEN_ENDPOINT missing from $PDV"

# https://praxis-1.verify.ibm.com/oauth2/token -> https://praxis-1.verify.ibm.com
TENANT_URL="${TOKEN_ENDPOINT%/oauth2/token}"
[ "$TENANT_URL" != "$TOKEN_ENDPOINT" ] \
  || die "could not derive tenant URL from IBM_VERIFY_TOKEN_ENDPOINT ('$TOKEN_ENDPOINT'); expected it to end in /oauth2/token"

# .env.verify is gitignored and holds the admin API client. Prefer an already
# exported value so CI or a one-off run can override without editing the file.
if [ -f "$DEMO_DIR/.env.verify" ]; then
  # shellcheck disable=SC1091
  set -a; . "$DEMO_DIR/.env.verify"; set +a
fi

ADMIN_ID="${VERIFY_ADMIN_CLIENT_ID:-}"
ADMIN_SECRET="${VERIFY_ADMIN_CLIENT_SECRET:-}"

if [ "$DRY_RUN" = false ] && { [ -z "$ADMIN_ID" ] || [ -z "$ADMIN_SECRET" ]; }; then
  cat >&2 <<EOF
$(red 'ERROR:') VERIFY_ADMIN_CLIENT_ID / VERIFY_ADMIN_CLIENT_SECRET are not set.

The Applications API needs an API client with the 'manageAppAccessAdmin'
entitlement ("Manage application lifecycle"). This is deliberately NOT one of
the demo clients — see the header of this script.

  1. Verify admin console -> Security -> API access -> Add API client
  2. Grant: "Manage application lifecycle"
     (add it to the same client import-verify-users.sh uses, which already has
      "Manage users and groups" + "Manage attributes")
  3. Add the credentials to $DEMO_DIR/.env.verify:

       VERIFY_ADMIN_CLIENT_ID=<uuid>
       VERIFY_ADMIN_CLIENT_SECRET=<secret>

Re-run with --dry-run to inspect the payloads without any credentials.
EOF
  exit 1
fi

# --- access token ---------------------------------------------------------
ACCESS_TOKEN=""
get_token() {
  local resp
  resp=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=$ADMIN_ID" \
    -d "client_secret=$ADMIN_SECRET") || die "token request to $TOKEN_ENDPOINT failed"

  ACCESS_TOKEN=$(printf '%s' "$resp" | jq -r '.access_token // empty')
  if [ -z "$ACCESS_TOKEN" ]; then
    fail "admin token" "$(printf '%s' "$resp" | jq -r '.error_description // .error // "no access_token in response"')"
    printf '%s\n' "$resp" | jq . >&2 || printf '%s\n' "$resp" >&2
    die "could not obtain an admin access token"
  fi
  ok "admin token" "$(dim "client ${ADMIN_ID:0:8}…")"
}

# api <METHOD> <PATH> [BODY] -> prints "<body>\n<http_status>"
# The Applications API is plain JSON, unlike the SCIM Users API.
api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "${TENANT_URL}${path}"
    -H "Authorization: Bearer $ACCESS_TOKEN"
    -H "Accept: application/json")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}"
}

# Split "<body>\n<status>" from api() into the globals RESP_BODY / RESP_STATUS.
_split_resp() {
  RESP_STATUS="${1##*$'\n'}"
  RESP_BODY="${1%$'\n'*}"
}

# Parse CSV by column name, supporting quoting, CRLF, and ## comment lines.
csv_json() {
  python3 - "$CSV" <<'PY'
import csv, json, sys

REQUIRED = ["name", "role"]
FLAGS    = ["ropc", "client_creds", "token_exchange"]
LISTS    = ["audiences", "claims"]
OPTIONAL = ["pdv_id_key", "pdv_secret_key"]
ROLES    = {"mint", "exchange", "audience", "agent"}

with open(sys.argv[1], newline="") as fh:
    # '##' lines are documentation, not data. Blank lines are skipped so the
    # file can be visually grouped.
    rows = [ln for ln in fh if not ln.lstrip().startswith("##") and ln.strip()]

reader = csv.DictReader(rows)
missing = [c for c in REQUIRED + FLAGS if c not in (reader.fieldnames or [])]
if missing:
    sys.exit(f"clients.csv is missing required column(s): {', '.join(missing)}\n"
             f"found: {', '.join(reader.fieldnames or [])}")

def flag(row, key, line):
    raw = (row.get(key) or "").strip().lower()
    if raw in ("true", "yes", "1"):  return True
    if raw in ("false", "no", "0", ""): return False
    sys.exit(f"row {line}: {key} must be true or false, got {raw!r}")

out, seen = [], set()
for i, row in enumerate(reader, start=2):
    c = {k: (row.get(k) or "").strip() for k in REQUIRED + OPTIONAL}
    if not c["name"]:
        sys.exit(f"row {i}: empty name")
    if c["name"] in seen:
        sys.exit(f"row {i}: duplicate client name {c['name']!r}")
    seen.add(c["name"])
    if c["role"] not in ROLES:
        sys.exit(f"row {i}: role must be one of {sorted(ROLES)}, got {c['role']!r}")
    for k in FLAGS:
        c[k] = flag(row, k, i)
    for k in LISTS:
        raw = (row.get(k) or "").strip()
        c[k] = [v.strip() for v in raw.split("|") if v.strip()]
    # Reject rows with no enabled grant (CSIAQ0032).
    if not any(c[k] for k in FLAGS):
        sys.exit(f"row {i}: {c['name']!r} enables no grant type, which Verify "
                 f"rejects (CSIAQ0032). Even a placeholder needs one — "
                 f"client_creds=true is the narrowest.")
    # A write-back needs both halves or neither; a half-written pair would leave
    # post_deploy_variables.json describing a client that cannot authenticate.
    if bool(c["pdv_id_key"]) != bool(c["pdv_secret_key"]):
        sys.exit(f"row {i}: pdv_id_key and pdv_secret_key must both be set or both be empty")
    out.append(c)

if not out:
    sys.exit("clients.csv contains no client rows")
json.dump(out, sys.stdout)
PY
}

CLIENTS_JSON="$(csv_json)" || die "failed to parse $CSV"
CLIENT_COUNT=$(printf '%s' "$CLIENTS_JSON" | jq 'length')

# Set-valued claim mapper. %s is the SCIM attribute name.
# Return [] for missing attributes; claim_mapper: ibmverify handles scalar values.
SET_CEL='statements:
  - context: values := user.getCustomValues("%s")
  - context: "safeValues := context.values == null ? [] : context.values"
  - return: context.safeValues'

# Read the manager relationship as a scalar userName for CIBA login_hint.
# This mapper takes no SCIM attribute name.
MANAGER_CEL='statements:
  - context: manager := user.getManager()
  - return: context.manager.userName'

# Relationship claims use dedicated mappers and skip attribute-name lookup.
RELATIONSHIP_CLAIMS=" manager "

is_relationship_claim() {
  case "$RELATIONSHIP_CLAIMS" in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# The CELx for a relationship claim. Separate function so adding a second one
# (a user's department, say) does not mean touching app_payload().
relationship_cel() {
  case "$1" in
    manager) printf '%s' "$MANAGER_CEL" ;;
    *) die "no CELx defined for relationship claim '$1'" ;;
  esac
}

# Resolved at run time into "claim=scimName" pairs by resolve_scim_names().
declare -a SCIM_MAP=()

scim_name_for() {
  local claim="$1" entry
  # ${arr[@]} on an empty array trips `set -u` on bash 3.2 (macOS), so guard it.
  if [ "${#SCIM_MAP[@]}" -gt 0 ]; then
    for entry in "${SCIM_MAP[@]}"; do
      [ "${entry%%=*}" = "$claim" ] && { printf '%s' "${entry#*=}"; return 0; }
    done
  fi
  # Dry-run fallback: use the display name when tenant discovery is unavailable.
  printf '%s' "$claim"
}

# Resolve SCIM names from /v1.0/attributes; fail if a required attribute is absent.
resolve_scim_names() {
  local claims attrs_json
  # Exclude relationship claims from custom-attribute lookup.
  claims=$(printf '%s' "$CLIENTS_JSON" | jq -r --arg rel "$RELATIONSHIP_CLAIMS" '
    ($rel | split(" ") | map(select(. != ""))) as $skip
    | [.[].claims[]] | unique | map(select(. as $c | $skip | index($c) | not)) | .[]')
  [ -n "$claims" ] || return 0

  _split_resp "$(api GET "/v1.0/attributes?limit=200")"
  [ "$RESP_STATUS" = "200" ] || die "could not list /v1.0/attributes (HTTP $RESP_STATUS) — the admin client needs the 'manageAttributes' entitlement"
  attrs_json="$RESP_BODY"

  local claim scim
  while IFS= read -r claim; do
    [ -n "$claim" ] || continue
    # Accept both bare and wrapped attribute arrays.
    scim=$(printf '%s' "$attrs_json" | jq -r --arg n "$claim" '
      (if type == "array" then . else (._embedded.attributes // .attributes // []) end)
      | map(select(.name == $n))
      | (.[0].schemaAttribute.scimName // .[0].scimName // empty)')
    if [ -z "$scim" ]; then
      fail "$claim" "no custom attribute named '$claim' on the tenant"
      echo "$(dim '      Run ./verify/import-verify-users.sh --attrs-only first: a mapper for')" >&2
      echo "$(dim '      an undefined attribute is created happily and then yields nothing,')" >&2
      echo "$(dim '      which presents as a policy deny rather than a config error.')" >&2
      die "cannot build a claim mapper for '$claim'"
    fi
    SCIM_MAP+=("$claim=$scim")
  done <<< "$claims"
}

# --- payload --------------------------------------------------------------
# Build the POST /v1.0/applications body for the client at index $1.
app_payload() {
  local i="$1" claim scim cel
  local mappers='[]'

  while IFS= read -r claim; do
    [ -n "$claim" ] || continue
    # Relationship claims use literal CELx; custom claims use the set mapper.
    if is_relationship_claim "$claim"; then
      cel="$(relationship_cel "$claim")"
    else
      scim="$(scim_name_for "$claim")"
      # shellcheck disable=SC2059
      cel="$(printf "$SET_CEL" "$scim")"
    fi
    mappers=$(printf '%s' "$mappers" | jq --arg t "$claim" --arg c "$cel" \
      '. + [{targetName: $t, function: {custom: $c}}]')
  done <<< "$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].claims[]?")"

  printf '%s' "$CLIENTS_JSON" | jq \
    --argjson i "$i" \
    --arg template "$TEMPLATE_ID" \
    --arg alg "$SIGNING_ALG" \
    --arg purpose "$CONSENT_PURPOSE_ID" \
    --argjson mappers "$mappers" '
    .[$i] as $c
    | ($c.ropc           | if . then "true" else "false" end) as $ropc
    | ($c.client_creds   | if . then "true" else "false" end) as $cc
    | ($c.token_exchange | if . then "true" else "false" end) as $te
    | {
        name: $c.name,
        templateId: $template,
        # false would leave the application in draft and unable to issue tokens.
        applicationState: true,
        description: ("Policy-engine demo (" + $c.role + ") — created by verify/import-verify-clients.sh from keycloak/realm-export.json"),
        providers: {
          # Custom OIDC applications require sso.userOptions=oidc.
          sso: { userOptions: "oidc" },
          oidc: {
            properties: {
              # Grant types are the STRINGS "true"/"false", not booleans.
              grantTypes: {
                ropc: $ropc,
                clientCredentials: $cc,
                tokenExchange: $te,
                authorizationCode: "false",
                implicit: "false",
                jwtBearer: "false",
                deviceFlow: "false",
                policyAuth: "false",
                ciba: "true"
              },
              # Unused by the demo (no browser leg) but Verify wants the field
              # present; matches what the tenant'"'"'s working clients carry.
              redirectUris: ["https://localhost:8443"],
              # JWT access tokens require idTokenSigningAlg (CSIAQ0257).
              idTokenSigningAlg: $alg,
              doNotGenerateClientSecret: false,
              additionalConfig: ({
                # Enable application entitlement for mint and exchange subjects (CSIAQ0279E).
                # Grants are managed separately under /v1.0/owner/applications/{id}/entitlements.
                useUserDefaultEntitlements: ($c.role == "mint")
                # Token exchange requires subjectTokenTypes and requestedTokenTypes under
                # additionalConfig. A missing subjectTokenTypes fails with CSIAQ0377.
              }
              + (if $c.token_exchange then {
                  subjectTokenTypes:   ["urn:ietf:params:oauth:token-type:access_token"],
                  actorTokenTypes:   ["urn:ietf:params:oauth:token-type:access_token"],
                  requestedTokenTypes: ["urn:ietf:params:oauth:token-type:access_token"],
                  # For DPCM consent, prepend an auto-granted purpose for the requested audience.
                  # Preserve scope and authorization_details. Purpose id must match the exchange
                  # request. tokenRequestMap entries are {name, custom}, with no function wrapper.
                  tokenRequestMap: [
                    {
                      name: "scope",
                      custom: ("(requestContext.getValue(\"audience\") != \"\" ? "
                               + "[{\"purpose\": \"" + $purpose + "\", "
                               + "\"audience\": requestContext.getValue(\"audience\"), "
                               + "\"autoGrant\": true}] : []) "
                               + "+ requestContext.scope + requestContext.authorization_details")
                    }
                  ]
                } else {} end))
            },
            token: {
              # Use JWT access tokens so Praxis can validate them against the tenant JWKS.
              accessTokenType: "jwt",
              audiences: $c.audiences,
              attributeMappings: $mappers
            }
          }
        },
        # Required at the top level; the demo provisions no accounts downstream.
        provisioning: {}
      }'
}

# Discover the tenant OIDC template id and each claim attribute SCIM name.
discover() {
  echo
  echo "$(dim 'Tenant facts') $(dim "-> ${TENANT_URL}")"

  _split_resp "$(api GET "/v1.0/applications?limit=200")"
  if [ "$RESP_STATUS" != "200" ]; then
    fail "applications" "HTTP $RESP_STATUS"
    [ "$RESP_STATUS" = "403" ] && echo "$(dim "      the admin client lacks the 'manageAppAccessAdmin' entitlement")"
    die "could not list applications"
  fi

  # api() overwrites RESP_BODY on every call, and the loop below issues one GET
  # per application, so keep the listing.
  RESP_BODY_LIST="$RESP_BODY"

  local tmpl
  tmpl=$(printf '%s' "$RESP_BODY" | jq -r '
    [._embedded.applications[]?.templateId] | map(select(. != null))
    | group_by(.) | map({t: .[0], n: length}) | sort_by(-.n)
    | map("\(.t) (\(.n) app\(if .n == 1 then "" else "s" end))") | join(", ")')
  ok "templateId in use" "$(dim "${tmpl:-none found}")"
  if [ -n "$tmpl" ] && ! printf '%s' "$tmpl" | grep -q "^$TEMPLATE_ID "; then
    warn "templateId default" "$(dim "using $TEMPLATE_ID; override with --template-id if that is wrong")"
  fi

  echo
  echo "$(dim 'Existing applications')"
  # The LIST response omits clientId — only the per-application GET carries it,
  # so fetch each one rather than printing a column of "-".
  local aid aname acid n who
  while IFS=$'\t' read -r aid aname; do
    [ -n "$aid" ] || continue
    _split_resp "$(api GET "/v1.0/applications/$aid")"
    acid=$(printf '%s' "$RESP_BODY" | jq -r '.providers.oidc.properties.clientId // "-"' 2>/dev/null || echo "-")
    printf '  %-34s %s\n' "$aname" "$(dim "$acid")"
  done <<< "$(printf '%s' "$RESP_BODY_LIST" | jq -r '._embedded.applications[]?
    | "\(._links.self.href | sub("^.*/applications/"; ""))\t\(.name)"')"

  echo
  echo "$(dim 'Consent purpose') $(dim "(the DPCM resource the tokenRequestMap grants against)")"
  # Reported because a missing or draft purpose presents at exchange time as a
  # consent failure, which looks like a client problem rather than this one.
  local pstate pactive pfound
  if pfound=$(find_purpose) && [ -n "$pfound" ]; then
    pstate=$(printf '%s' "$pfound" | cut -f1)
    pactive=$(printf '%s' "$pfound" | cut -f2)
    if [ "$pstate" = "1" ] && [ -n "$pactive" ]; then
      ok "$CONSENT_PURPOSE_ID" "$(dim "active v$pactive")"
    else
      warn "$CONSENT_PURPOSE_ID" "$(dim "state=$pstate, activeVersion=${pactive:-<none>} — a DRAFT; the exchange will fail at DPCM until it is published")"
    fi
  else
    warn "$CONSENT_PURPOSE_ID" "$(dim 'not defined on this tenant — a run without --no-purpose creates it')"
  fi

  echo
  echo "$(dim 'Consent') $(dim '(consentType + the exchange tokenRequestMap purpose)')"
  # Report the tenant-wide consentType; the request mapping requires dpcm.
  local ctype trmn trmp
  while IFS=$'\t' read -r aid aname; do
    [ -n "$aid" ] || continue
    _split_resp "$(api GET "/v1.0/applications/$aid")"
    ctype=$(printf '%s' "$RESP_BODY" | jq -r '.providers.oidc.properties.consentType // "-"')
    trmn=$(printf '%s' "$RESP_BODY" | jq -r \
      '[.providers.oidc.properties.additionalConfig.tokenRequestMap[]?.name] | join(",")')
    # The purpose id is embedded in the CELx, not a field of its own.
    trmp=$(printf '%s' "$RESP_BODY" | jq -r \
      '[.providers.oidc.properties.additionalConfig.tokenRequestMap[]?.custom]
       | join(" ") | capture("\"purpose\"\\s*:\\s*\"(?<p>[^\"]+)\"").p // empty' 2>/dev/null || true)
    if [ -z "$trmn" ]; then
      printf '  %-34s %s\n' "$aname" "$(dim "consentType=$ctype  tokenRequestMap=none")"
    elif [ "$trmp" = "$CONSENT_PURPOSE_ID" ]; then
      ok "$aname" "$(dim "consentType=$ctype  maps [$trmn]  purpose=$trmp")"
    else
      warn "$aname" "$(dim "consentType=$ctype  maps [$trmn]  purpose=${trmp:-<none>} — script sends $CONSENT_PURPOSE_ID")"
    fi
  done <<< "$(printf '%s' "$RESP_BODY_LIST" | jq -r '._embedded.applications[]?
    | "\(._links.self.href | sub("^.*/applications/"; ""))\t\(.name)"')"

  echo
  echo "$(dim 'Application entitlement') $(dim '(who may sign on — GET /v1.0/owner/applications/<id>/entitlements)')"
  while IFS=$'\t' read -r aid aname; do
    [ -n "$aid" ] || continue
    _split_resp "$(api GET "/v1.0/owner/applications/$aid/entitlements")"
    if [ "$RESP_STATUS" != "200" ]; then
      warn "$aname" "$(dim "could not read (HTTP $RESP_STATUS)")"
      continue
    fi
    printf '%s' "$RESP_BODY" | jq -e '.birthRightAccess == true' >/dev/null 2>&1 \
      && { ok "$aname" "$(dim 'all tenant users (birthright)')"; continue; }
    n=$(printf '%s' "$RESP_BODY" | jq -r '[.entitlements[]?] | length')
    if [ "$n" = "0" ]; then
      warn "$aname" "$(dim 'nobody entitled (fine unless users authenticate to it)')"
    else
      who=$(printf '%s' "$RESP_BODY" | jq -r '[.entitlements[]?.assignee.userName] | join(", ")')
      ok "$aname" "$(dim "$n grant(s): $who")"
    fi
  done <<< "$(printf '%s' "$RESP_BODY_LIST" | jq -r '._embedded.applications[]?
    | "\(._links.self.href | sub("^.*/applications/"; ""))\t\(.name)"')"

  echo
  echo "$(dim 'Claim -> scimName') $(dim '(what the CELx mappers will call)')"
  local entry claim scim
  # Relationship claims resolve nothing, so they are absent from SCIM_MAP and
  # listed separately rather than being silently omitted.
  for claim in $RELATIONSHIP_CLAIMS; do
    printf '%s' "$CLIENTS_JSON" | jq -e --arg c "$claim" \
      '[.[].claims[]] | index($c) != null' >/dev/null 2>&1 \
      && ok "$claim" "$(dim 'getManager().userName -> scalar string (relationship, not an attribute)')"
  done
  if [ "${#SCIM_MAP[@]}" -eq 0 ]; then
    warn "claims" "$(dim 'no attribute-backed claim mappers configured in the CSV')"
    return 0
  fi
  for entry in "${SCIM_MAP[@]}"; do
    claim="${entry%%=*}"; scim="${entry#*=}"
    if [ "$claim" = "$scim" ]; then
      ok "$claim" "$(dim "getCustomValues(\"$scim\") -> array")"
    else
      warn "$claim" "$(dim "getCustomValues(\"$scim\") -> array — scimName differs from the display name")"
    fi
  done
}

# DPCM purposes use /config/v1.0/privacy/purposes. POST creates a draft;
# publish with a versioned PATCH before clients reference it.
# api_dpcm() detects HTML login redirects that incorrectly return HTTP 200.
PURPOSE_PATH="/config/v1.0/privacy/purposes"

# Reject HTML responses from unknown DPCM paths, even when HTTP status is 200.
api_dpcm() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "${TENANT_URL}${path}"
    -H "Authorization: Bearer $ACCESS_TOKEN"
    -H "Accept: application/json")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  local raw
  raw="$(curl "${args[@]}")" || return 1
  case "${raw%$'\n'*}" in
    '<!DOCTYPE html>'*|'<html'*)
      printf 'the tenant served an HTML login-redirect for %s (DPCM API path or entitlement is wrong)\n000\n' "$path"
      return 0 ;;
  esac
  printf '%s\n' "$raw"
}

# Reuse the payload for creation and publication; POST ignores state.
purpose_payload() {
  jq -n \
    --arg id       "$CONSENT_PURPOSE_ID" \
    --arg name     "$CONSENT_PURPOSE_NAME" \
    --arg desc     "$CONSENT_PURPOSE_DESC" \
    --arg access   "$CONSENT_PURPOSE_ACCESS_TYPE" \
    --arg tags     "$CONSENT_PURPOSE_TAGS" \
    --argjson days "$CONSENT_PURPOSE_DURATION" '
    {
      id: $id,
      name: $name,
      description: $desc,
      # 1 = active. Ignored by POST (always a draft), honoured by the PUT.
      state: 1,
      defaultConsentDuration: $days,
      # Whether an existing consent for an earlier version carries forward. The
      # tenant has this false, and for an auto-granted purpose it is moot.
      previousConsentApply: false,
      tags: ($tags | split("|") | map(select(length > 0))),
      category: "default",
      accessTypes: [{ id: $access }],
      # Audience purposes require an empty attributes list.
      attributes: [],
      customAttributes: []
    }'
}

# Return state, activeVersion, and version, or empty if the purpose is absent.
# A draft has no activeVersion; publication requires its version number.
find_purpose() {
  _split_resp "$(api_dpcm GET "${PURPOSE_PATH}/${CONSENT_PURPOSE_ID}")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r '"\(.state // 0)\t\(.activeVersion // "")\t\(.version // 0)"'
}

# Publish with PATCH /config/v1.0/privacy/purposes/<id>/<version>.
# Use a single {op: replace, path: state, value: 1} object. The path has no
# leading slash. Unversioned updates create drafts instead of publishing.
publish_purpose() {
  local version="$1"
  _split_resp "$(api_dpcm PATCH "${PURPOSE_PATH}/${CONSENT_PURPOSE_ID}/${version}" \
    '{"op":"replace","path":"state","value":1}')"
  case "$RESP_STATUS" in
    200|204) return 0 ;;
    *) return 1 ;;
  esac
}

create_purpose() {
  echo
  echo "$(dim 'Consent purpose') $(dim "-> ${TENANT_URL}${PURPOSE_PATH}")"
  local body existing state active draftver

  body="$(purpose_payload)"

  if [ "$DRY_RUN" = true ]; then
    ok "$CONSENT_PURPOSE_ID" "$(dim 'dry-run — POST the draft, then PATCH state=1 to publish')"
    printf '%s\n' "$body" | jq . | sed 's/^/      /'
    return 0
  fi

  # Leave active purposes unchanged; republishing invalidates existing consents.
  if existing=$(find_purpose) && [ -n "$existing" ]; then
    state=$(printf '%s' "$existing" | cut -f1)
    active=$(printf '%s' "$existing" | cut -f2)
    draftver=$(printf '%s' "$existing" | cut -f3)
    if [ -n "$active" ] && [ "$state" = "1" ]; then
      warn "$CONSENT_PURPOSE_ID" "$(dim "exists (active v$active) — left unchanged")"
      return 0
    fi
    # Present but unpublished: finish the job instead of reporting a false pass.
    warn "$CONSENT_PURPOSE_ID" "$(dim "exists as an unpublished draft (v$draftver) — publishing")"
    if publish_purpose "$draftver"; then
      ok "$CONSENT_PURPOSE_ID" "$(dim 'published')"
      return 0
    fi
    fail "$CONSENT_PURPOSE_ID" "HTTP $RESP_STATUS publishing the existing draft"
    printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
      || printf '      %s\n' "$RESP_BODY"
    die "could not publish the '$CONSENT_PURPOSE_ID' draft"
  fi

  _split_resp "$(api_dpcm POST "$PURPOSE_PATH" "$body")"
  case "$RESP_STATUS" in
    200|201)
      # Created as a draft. Publishing needs the draft's version in the PATCH
      # path and the 201 body is empty, so read it back rather than assuming 0.
      if ! existing=$(find_purpose) || [ -z "$existing" ]; then
        fail "$CONSENT_PURPOSE_ID" 'created but could not be read back to publish'
        die "purpose '$CONSENT_PURPOSE_ID' exists only as a draft — the exchange will fail at DPCM"
      fi
      draftver=$(printf '%s' "$existing" | cut -f3)
      # Publish, then prove it took: an unpublished purpose fails at exchange
      # time as a consent error, far from here.
      if ! publish_purpose "$draftver"; then
        fail "$CONSENT_PURPOSE_ID" "created as a draft but HTTP $RESP_STATUS publishing it"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        die "purpose '$CONSENT_PURPOSE_ID' exists only as a draft — the exchange will fail at DPCM"
      fi
      if existing=$(find_purpose) \
         && [ "$(printf '%s' "$existing" | cut -f1)" = "1" ] \
         && [ -n "$(printf '%s' "$existing" | cut -f2)" ]; then
        ok "$CONSENT_PURPOSE_ID" \
           "$(dim "created and published (active v$(printf '%s' "$existing" | cut -f2))")"
      else
        fail "$CONSENT_PURPOSE_ID" 'created but did not read back as active'
        die "purpose '$CONSENT_PURPOSE_ID' is not active — check the console under Data privacy & consent"
      fi ;;
    # The collection POST reports a duplicate this way. Reachable when a purpose
    # is created between find_purpose() and here.
    409)
      warn "$CONSENT_PURPOSE_ID" "$(dim 'already exists (409) — left unchanged')" ;;
    403)
      fail "$CONSENT_PURPOSE_ID" "HTTP 403 — the API client cannot manage privacy purposes"
      echo "$(dim '      Grant the admin API client the DPCM configuration entitlement')" >&2
      echo "$(dim '      ("Manage privacy purposes" / Data Privacy & Consent config) and re-run.')" >&2
      die "insufficient entitlements for $PURPOSE_PATH" ;;
    000)
      fail "$CONSENT_PURPOSE_ID" 'the DPCM API did not answer with JSON'
      printf '      %s\n' "$RESP_BODY"
      die "cannot reach the purposes API at $PURPOSE_PATH" ;;
    *)
      fail "$CONSENT_PURPOSE_ID" "HTTP $RESP_STATUS"
      printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
        || printf '      %s\n' "$RESP_BODY"
      die "unexpected response creating purpose '$CONSENT_PURPOSE_ID'" ;;
  esac
}

delete_purpose() {
  echo
  echo "$(yellow 'Deleting') $(dim "purpose $CONSENT_PURPOSE_ID from ${TENANT_URL}")"

  if [ "$DRY_RUN" = true ]; then
    ok "$CONSENT_PURPOSE_ID" "$(dim "(dry-run) would DELETE ${PURPOSE_PATH}/${CONSENT_PURPOSE_ID}")"
    return 0
  fi

  _split_resp "$(api_dpcm DELETE "${PURPOSE_PATH}/${CONSENT_PURPOSE_ID}")"
  case "$RESP_STATUS" in
    200|204) ok   "$CONSENT_PURPOSE_ID" "$(dim 'deleted')" ;;
    404)     warn "$CONSENT_PURPOSE_ID" "$(dim 'not present — nothing to delete')" ;;
    # A purpose with consents recorded against it cannot be removed. Not fatal:
    # --delete is about the demo's clients, and a lingering purpose is inert.
    409)     warn "$CONSENT_PURPOSE_ID" "$(dim 'in use (409) — left in place')" ;;
    *)       fail "$CONSENT_PURPOSE_ID" "HTTP $RESP_STATUS"
             printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
               || printf '      %s\n' "$RESP_BODY" ;;
  esac
}

# Look up an application by name -> id<TAB>clientId.
# Filter locally because this endpoint search syntax is undocumented.
find_app() {
  local name="$1" id
  _split_resp "$(api GET "/v1.0/applications?limit=200")"
  [ "$RESP_STATUS" = "200" ] || return 1
  id=$(printf '%s' "$RESP_BODY" | jq -r --arg n "$name" '
    [._embedded.applications[]? | select(.name == $n)
     | (._links.self.href | sub("^.*/applications/"; ""))] | .[0] // empty')
  [ -n "$id" ] || return 1
  # The list response has no clientId — only the per-application GET does.
  _split_resp "$(api GET "/v1.0/applications/$id")"
  printf '%s\t%s\n' "$id" \
    "$(printf '%s' "$RESP_BODY" | jq -r '.providers.oidc.properties.clientId // "-"' 2>/dev/null || echo '-')"
}

# The 201 response carries only _links.self.href — the generated clientId and
# clientSecret are NOT in it. Read them back from the created application.
fetch_credentials() {
  local id="$1"
  _split_resp "$(api GET "/v1.0/applications/$id")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r '
    "\(.providers.oidc.properties.clientId // "")\t\(.providers.oidc.properties.clientSecret // "")"'
}

# Keep generated name/id/secret tuples in memory until write_back().
declare -a CREATED=()
# Clients created in this run whose entitlement did NOT get granted — skipped
# with --no-entitle, or the grant failed. These cannot mint until it is fixed.
declare -a NEEDS_ENTITLEMENT=()

create_clients() {
  echo
  echo "$(dim 'Applications') $(dim "-> ${TENANT_URL}/v1.0/applications")"
  local i name role body existing id cid secret

  for i in $(seq 0 $((CLIENT_COUNT - 1))); do
    name=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].name")
    role=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].role")
    body="$(app_payload "$i")"

    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim "$role (dry-run)")"
      printf '%s\n' "$body" | jq . | sed 's/^/      /'
      continue
    fi

    # Creating a second application with the same name would leave two clients
    # and no way to tell which one the config refers to.
    if existing=$(find_app "$name") && [ -n "$existing" ]; then
      warn "$name" "$(dim "exists (client_id=$(printf '%s' "$existing" | cut -f2)) — left unchanged; use --delete to replace")"
      # Preserve existing applications and repair exchange entitlement for agent subjects.
      if [ "$role" = "exchange" ] && [ "$DO_ENTITLE" = true ]; then
        local ag_rows
        ag_rows=$(printf '%s' "$CLIENTS_JSON" | jq '[.[] | select(.role=="agent")] | length')
        if [ "$ag_rows" -gt 0 ]; then
          entitle_app "$(printf '%s' "$existing" | cut -f1)" "$name" \
            || NEEDS_ENTITLEMENT+=("$name")
        fi
      fi
      continue
    fi

    _split_resp "$(api POST "/v1.0/applications" "$body")"
    case "$RESP_STATUS" in
      201)
        id=$(printf '%s' "$RESP_BODY" | jq -r '._links.self.href // empty' | sed 's|^.*/applications/||')
        if [ -z "$id" ]; then
          fail "$name" "created but the response carried no application id"
          die "cannot read back credentials for '$name'"
        fi
        if ! creds=$(fetch_credentials "$id"); then
          fail "$name" "created (id=$id) but its credentials could not be read back"
          die "created '$name' but cannot read its client_id — check the console"
        fi
        cid=$(printf '%s' "$creds" | cut -f1)
        secret=$(printf '%s' "$creds" | cut -f2)
        ok "$name" "$(dim "$role — client_id=${cid:-?}")"
        CREATED+=("$name"$'\t'"$cid"$'\t'"$secret")
        # Both mint and exchange subjects need application entitlement (CSIAQ0279E).
        # Use explicit persona grants by default or birthright access with --all-users.
        # Audience-only clients do not need user grants.
        if [ "$role" = "mint" ] || [ "$role" = "exchange" ]; then
          if [ "$DO_ENTITLE" = true ]; then
            if ! entitle_app "$id" "$name"; then
              NEEDS_ENTITLEMENT+=("$name")
            fi
          else
            NEEDS_ENTITLEMENT+=("$name")
          fi
        fi
        ;;
      400)
        fail "$name" "HTTP 400"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        # The two 400s that actually happen, and what they mean.
        case "$RESP_BODY" in
          *CSIAQ0257*) echo "$(dim '      A JWT access token needs idTokenSigningAlg — see the script header.')" ;;
          *CSIAQ0377*) echo "$(dim '      token_exchange=true needs additionalConfig.subjectTokenTypes — see')"
                       echo "$(dim '      note 3a in the script header. A tenant that rejects the value this')"
                       echo "$(dim '      script sends would show its own in --discover.')" ;;
          *) echo "$(dim "      Often a templateId the tenant does not know. Run --discover to see")"
             echo "$(dim "      which templateId its own applications use.")" ;;
        esac
        die "client '$name' rejected" ;;
      403)
        fail "$name" "HTTP 403 — the API client lacks the 'manageAppAccessAdmin' entitlement"
        die "insufficient entitlements" ;;
      *)
        fail "$name" "HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        die "unexpected response creating '$name'" ;;
    esac
  done
}

delete_clients() {
  echo
  echo "$(yellow 'Deleting') $(dim "the ${CLIENT_COUNT} clients in $(basename "$CSV") from ${TENANT_URL}")"
  local i name found id
  for i in $(seq 0 $((CLIENT_COUNT - 1))); do
    name=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].name")

    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim '(dry-run) would DELETE /v1.0/applications/<id>')"
      continue
    fi

    if ! found=$(find_app "$name") || [ -z "$found" ]; then
      warn "$name" "$(dim 'not present — nothing to delete')"
      continue
    fi
    id=$(printf '%s' "$found" | cut -f1)
    _split_resp "$(api DELETE "/v1.0/applications/$id")"
    case "$RESP_STATUS" in
      200|204) ok   "$name" "$(dim "deleted (id=$id)")" ;;
      404)     warn "$name" "$(dim 'already gone')" ;;
      *)       fail "$name" "HTTP $RESP_STATUS"
               printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
                 || printf '      %s\n' "$RESP_BODY" ;;
    esac
  done
  echo
  echo "$(dim 'post_deploy_variables.json still names the deleted clients. Re-run without')"
  echo "$(dim '--delete to recreate them and refresh the ids there.')"
}

# ==========================================================================
# application entitlement
# ==========================================================================
# Resolve a userName -> SCIM id, needed for an explicit grant's subjectId.
scim_user_id() {
  local username="$1" filter
  filter="userName%20eq%20%22${username}%22"
  _split_resp "$(api_scim GET "/v2.0/Users?filter=${filter}")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r '.Resources[0].id // empty'
}

# The Users API speaks SCIM; the Applications API speaks plain JSON. Same token,
# different Accept, so entitlement work needs both.
api_scim() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "${TENANT_URL}${path}"
    -H "Authorization: Bearer $ACCESS_TOKEN"
    -H "Accept: application/scim+json; charset=utf-8")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/scim+json; charset=utf-8" -d "$body")
  fi
  curl "${args[@]}"
}

# The personas to entitle, read from users.csv so this script and the user
# importer cannot disagree about who the demo's users are.
entitle_usernames() {
  local users_csv="$SCRIPT_DIR/users.csv"
  [ -f "$users_csv" ] || return 0
  python3 - "$users_csv" <<'PY_INNER'
import csv, sys
with open(sys.argv[1], newline="") as fh:
    rows = [l for l in fh if not l.lstrip().startswith("##") and l.strip()]
for row in csv.DictReader(rows):
    name = (row.get("username") or "").strip()
    if name:
        print(name)
PY_INNER
}

# Grant sign-on entitlement for one application id.
# Without this a role=mint client rejects every password grant with CSIAQ0279E.
entitle_app() {
  local id="$1" name="$2" body payload_desc

  # Agent subjects have no SCIM user id for explicit grants. When an agent row
  # exists, the exchange application needs birthright entitlement.
  local agent_rows
  agent_rows=$(printf '%s' "$CLIENTS_JSON" | jq '[.[] | select(.role=="agent")] | length')
  local this_role
  this_role=$(printf '%s' "$CLIENTS_JSON" | jq -r --arg n "$name" '.[] | select(.name==$n) | .role')
  if [ "$ALL_USERS" != true ] && [ "$agent_rows" -gt 0 ] && [ "$this_role" = "exchange" ]; then
    _split_resp "$(api POST "/v1.0/owner/applications/$id/entitlements" \
      '{"birthRightAccess":true,"requestAccess":false}')"
    case "$RESP_STATUS" in
      200|201|204)
        ok "$name" "$(dim 'entitled: all principals (birthright) — required for the agent subject')"
        return 0 ;;
      *)
        fail "$name" "entitlement HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        echo "$(dim '      Scenario 14 will fail at delegate with CSIAQ0279E until this succeeds.')"
        return 1 ;;
    esac
  fi

  if [ "$ALL_USERS" = true ]; then
    body='{"birthRightAccess":true,"requestAccess":false}'
    payload_desc="all tenant users (birthright)"
  else
    # Explicit grants: one addition per persona, each needing a SCIM id.
    local -a additions=()
    local u uid missing=""
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      if uid=$(scim_user_id "$u") && [ -n "$uid" ]; then
        additions+=("$(jq -nc --arg i "$uid" '{assignee:{subjectId:$i,subjectType:"user"},grantType:"BRT"}')")
      else
        missing="${missing:+$missing, }$u"
      fi
    done <<< "$(entitle_usernames)"

    if [ -n "$missing" ]; then
      warn "$name" "$(dim "not entitled: user(s) not on the tenant — $missing")"
      echo "$(dim '      Run ./verify/import-verify-users.sh first, then re-run with --users-only')" >&2
    fi
    if [ "${#additions[@]}" -eq 0 ]; then
      fail "$name" "no demo users found to entitle"
      echo "$(dim '      Without an entitlement this client cannot mint (CSIAQ0279E).')" >&2
      echo "$(dim '      Create the users first, or use --all-users / --no-entitle.')" >&2
      return 1
    fi
    body=$(printf '%s\n' "${additions[@]}" | jq -sc \
      '{birthRightAccess:false,requestAccess:false,additions:.}')
    payload_desc="${#additions[@]} demo user(s)"
  fi

  if [ "$DRY_RUN" = true ]; then
    ok "$name" "$(dim "would entitle $payload_desc (dry-run)")"
    return 0
  fi

  _split_resp "$(api POST "/v1.0/owner/applications/$id/entitlements" "$body")"
  case "$RESP_STATUS" in
    200|201|204) ok "$name" "$(dim "entitled: $payload_desc")" ;;
    403) fail "$name" "HTTP 403 — needs manageAppAccessAdmin or manageAppAccessOwner"
         return 1 ;;
    *)   fail "$name" "entitlement failed: HTTP $RESP_STATUS"
         printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
           || printf '      %s\n' "$RESP_BODY"
         echo "$(dim '      The client exists but cannot mint until this succeeds (CSIAQ0279E).')" >&2
         return 1 ;;
  esac
}

# Save generated OAuth credentials in post_deploy_variables.json for the token
# scripts and policy renderer.
#
# Agent Registry setup: POST creates UNDER_REVIEW; promote with PUT.
# oauthClients requires the tenant issuer and is write-only. PUT replaces the
# full record, so re-send description, tags, and the client association.
# Warn and continue on tenants without Agent Registry (403/404).

# The Agents API speaks SCIM, which api() does not: it sends
# `Accept: application/json`. Hence a sibling rather than a reuse.
agents_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "${TENANT_URL}${path}"
    -H "Authorization: Bearer $ACCESS_TOKEN"
    -H "Accept: application/scim+json")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/scim+json" --data "$body")
  fi
  curl "${args[@]}"
}

# The `issuer` an oauthClients entry must carry. Behavior 2 above.
agent_client_issuer() {
  printf '%s/oauth2' "$TENANT_URL"
}

# Find an agent record by displayName. Used for idempotence and for --delete.
# Prints "<id>" on success; empty when absent.
find_agent() {
  local want="$1"
  _split_resp "$(agents_api GET "/v1.0/Agents?count=200")"
  case "$RESP_STATUS" in
    200) ;;
    *)   return 1 ;;
  esac
  printf '%s' "$RESP_BODY" | jq -r --arg n "$want" \
    '[.Resources[]? | select(.displayName==$n) | .id] | .[0] // empty'
}

agent_payload() {
  local name="$1" client_id="$2" status="${3:-ACTIVE}"
  jq -nc \
    --arg name "$name" \
    --arg cid "$client_id" \
    --arg iss "$(agent_client_issuer)" \
    --arg status "$status" \
    '{
      schemas: ["urn:ietf:params:scim:schemas:core:ibm:2.0:Agent"],
      displayName: $name,
      description: "Policy-engine demo agent principal — created by verify/import-verify-clients.sh",
      # Behavior 1: explicit, or the tenant stores UNDER_REVIEW.
      status: $status,
      # Behavior 2: issuer is required and tenant-specific.
      oauthClients: [{
        issuer: $iss,
        clientId: $cid,
        purposes: ["agent_id", "authentication"]
      }],
      tags: ["policy-engine-demo", "scenario-14"]
    }'
}

# Create the record for each role=agent row and associate its OAuth client.
# Appends "<name>\t<agent_id>" to AGENTS_CREATED for write-back.
declare -a AGENTS_CREATED=()
# "<client_id>\t<secret>" for the readAgents-only client, when one was made.
READER_CREATED=""
OPERATOR_CREATED=""

# Provision a readAgents API client for gateway status lookups.
# Keep its credentials in .env.verify, separate from provisioning credentials.
READER_CLIENT_NAME="${READER_CLIENT_NAME:-praxis-agent-status-reader}"
# Provision a separate manageAgentStatus client for status changes.
OPERATOR_CLIENT_NAME="${OPERATOR_CLIENT_NAME:-praxis-agent-status-operator}"

find_api_client() {
  local want="$1"
  _split_resp "$(api GET "/v1.0/apiclients?limit=200")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r --arg n "$want" \
    '[.apiClients[]? | select(.clientName==$n) | .id] | .[0] // empty'
}

# Create an absent API client and store client_id<TAB>secret in the named global.
_create_status_client() {
  local name="$1" entitlement="$2" out_var="$3"
  local body id

  body=$(jq -nc --arg name "$name" --arg ent "$entitlement" '{
    clientName: $name,
    enabled: true,
    entitlements: [$ent],
    additionalConfig: { clientAuthMethod: "default" }
  }')

  if [ "$DRY_RUN" = true ]; then
    ok "$name" "$(dim "(dry-run) would POST /v1.0/apiclients — $entitlement only")"
    return 0
  fi

  if id=$(find_api_client "$name") && [ -n "$id" ]; then
    warn "$name" "$(dim "exists (id=$id) — left unchanged; use --delete to replace")"
  else
    _split_resp "$(api POST "/v1.0/apiclients" "$body")"
    case "$RESP_STATUS" in
      200|201)
        # 201 carries no body, so the id comes from a lookup by name.
        if ! id=$(find_api_client "$name") || [ -z "$id" ]; then
          fail "$name" 'created but could not be found by name afterwards'
          return 0
        fi
        ;;
      403)
        warn "$name" "$(dim 'HTTP 403 — the admin client cannot create API clients')"
        echo "$(dim '      Grant it "Manage API clients", or create this client by hand with the')"
        echo "$(dim "      single entitlement $entitlement and set its id/secret in .env.verify.")"
        return 0 ;;
      *)
        fail "$name" "HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        return 0 ;;
    esac
  fi

  # The secret lives only on the single-client GET, not in the listing.
  _split_resp "$(api GET "/v1.0/apiclients/$id")"
  if [ "$RESP_STATUS" != "200" ]; then
    fail "$name" "could not read back credentials (HTTP $RESP_STATUS)"
    return 0
  fi
  local cid secret ents
  cid=$(printf '%s' "$RESP_BODY" | jq -r '.clientId // empty')
  secret=$(printf '%s' "$RESP_BODY" | jq -r '.clientSecret // empty')
  ents=$(printf '%s' "$RESP_BODY" | jq -r '[.entitlements[]?] | join(",")')
  if [ -z "$cid" ] || [ -z "$secret" ]; then
    fail "$name" 'credentials incomplete — set them by hand in .env.verify'
    return 0
  fi
  # Assert the blast radius rather than trusting the create: a client that came
  # back with more than it asked for is not the credential this is meant to be.
  if [ "$ents" = "$entitlement" ]; then
    ok "$name" "$(dim "client_id=${cid} — entitlements: $entitlement only")"
  else
    warn "$name" "$(dim "client_id=${cid} — UNEXPECTED entitlements: ${ents:-none}")"
    echo "$(dim "      Expected $entitlement alone. Narrow it in the console before relying on it.")"
  fi
  # Use indirect assignment for bash 3.2, which lacks nameref.
  eval "$out_var=\"\$cid\"\$'\\t'\"\$secret\""
}

# Reader: readAgents for the gateway. Operator: manageAgentStatus for status changes.
create_status_clients() {
  local agent_rows
  agent_rows=$(printf '%s' "$CLIENTS_JSON" | jq '[.[] | select(.role=="agent")] | length')
  # No agent, no agent-status credentials: they exist only for scenario 14.
  [ "$agent_rows" -gt 0 ] || return 0

  echo
  echo "$(dim 'Agent-status credentials') $(dim "-> ${TENANT_URL}/v1.0/apiclients")"
  _create_status_client "$READER_CLIENT_NAME"   readAgents        READER_CREATED
  _create_status_client "$OPERATOR_CLIENT_NAME" manageAgentStatus OPERATOR_CREATED
}

delete_status_clients() {
  local name id
  for name in "$READER_CLIENT_NAME" "$OPERATOR_CLIENT_NAME"; do
    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim '(dry-run) would DELETE /v1.0/apiclients/<id>')"
      continue
    fi
    if ! id=$(find_api_client "$name") || [ -z "$id" ]; then
      warn "$name" "$(dim 'not present — nothing to delete')"
      continue
    fi
    _split_resp "$(api DELETE "/v1.0/apiclients/$id")"
    case "$RESP_STATUS" in
      200|204) ok   "$name" "$(dim "deleted (id=$id)")" ;;
      404)     warn "$name" "$(dim 'already gone')" ;;
      *)       fail "$name" "HTTP $RESP_STATUS" ;;
    esac
  done
}

create_agents() {
  local i name role cid body existing
  local any=false
  for i in $(seq 0 $((CLIENT_COUNT - 1))); do
    role=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].role")
    [ "$role" = "agent" ] || continue
    name=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].name")

    if [ "$any" = false ]; then
      echo
      echo "$(dim 'Agent Registry') $(dim "-> ${TENANT_URL}/v1.0/Agents")"
      any=true
    fi

    # The client_id this run created, or the one already in the PDV file.
    cid=""
    local entry
    for entry in ${CREATED[@]+"${CREATED[@]}"}; do
      if [ "${entry%%$'\t'*}" = "$name" ]; then
        cid=$(printf '%s' "$entry" | cut -f2)
        break
      fi
    done
    if [ -z "$cid" ] && [ -f "$PDV" ]; then
      local id_key
      id_key=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].pdv_id_key")
      [ -n "$id_key" ] && [ "$id_key" != "null" ] && \
        cid=$(jq -r --arg k "$id_key" '.variables[$k] // empty' "$PDV" 2>/dev/null)
    fi

    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim '(dry-run) would POST /v1.0/Agents')"
      agent_payload "$name" "${cid:-<client-id>}" | jq . | sed 's/^/      /'
      continue
    fi

    if [ -z "$cid" ]; then
      warn "$name" "$(dim 'no client_id known — cannot associate; skipping the registry record')"
      continue
    fi

    # Idempotence: a duplicate displayName is a 409, so check first.
    if existing=$(find_agent "$name") && [ -n "$existing" ]; then
      warn "$name" "$(dim "agent record exists (id=$existing) — left unchanged; use --delete to replace")"
      AGENTS_CREATED+=("$name"$'\t'"$existing")
      continue
    fi

    body="$(agent_payload "$name" "$cid" ACTIVE)"
    _split_resp "$(agents_api POST "/v1.0/Agents" "$body")"
    case "$RESP_STATUS" in
      200|201)
        local aid stored
        aid=$(printf '%s' "$RESP_BODY" | jq -r '.id // empty')
        stored=$(printf '%s' "$RESP_BODY" | jq -r '.status // empty')
        if [ -z "$aid" ]; then
          fail "$name" 'created but the response carried no agent id'
          continue
        fi
        # Behavior 1: the POST stores UNDER_REVIEW whatever we asked for, so
        # promote with a PUT. A full replace, hence the whole record.
        if [ "$stored" = "ACTIVE" ]; then
          ok "$name" "$(dim "agent record created (id=$aid, status=ACTIVE)")"
        else
          local promo
          _split_resp "$(agents_api PUT "/v1.0/Agents/$aid" "$(agent_payload "$name" "$cid" ACTIVE)")"
          case "$RESP_STATUS" in
            200|204)
              promo=$(agents_api GET "/v1.0/Agents/$aid" | sed '$d' | jq -r '.status // empty')
              if [ "$promo" = "ACTIVE" ]; then
                ok "$name" "$(dim "agent record created (id=$aid) — ${stored:-?} promoted to ACTIVE")"
              else
                warn "$name" "$(dim "agent record created (id=$aid) but status is ${promo:-?}, not ACTIVE")"
                echo "$(dim "      Fix with: ./verify/set-agent-status.sh ACTIVE")"
              fi ;;
            403)
              warn "$name" "$(dim "agent record created (id=$aid, status=${stored:-?}) — no entitlement to promote it")"
              echo "$(dim '      The admin client needs manageAgentStatus (or tenantAdmin) to set status.')"
              echo "$(dim '      Until it is ACTIVE the gateway denies the agent (auth.agent_suspended).')" ;;
            *)
              warn "$name" "$(dim "agent record created (id=$aid, status=${stored:-?}) — promotion returned HTTP $RESP_STATUS")"
              echo "$(dim '      Fix with: ./verify/set-agent-status.sh ACTIVE')" ;;
          esac
        fi
        # Behavior 3: do NOT read oauthClients back to confirm association —
        # it is write-only and always returns null.
        AGENTS_CREATED+=("$name"$'\t'"$aid")
        ;;
      403|404)
        warn "$name" "$(dim "Agent Registry unavailable (HTTP $RESP_STATUS) — skipping")"
        echo "$(dim '      Agent identity is an Early Access capability. The OAuth client was')"
        echo "$(dim '      still created; scenario 14 will skip until the registry is enabled.')"
        ;;
      *)
        fail "$name" "HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        case "$RESP_BODY" in
          *CSINH2100E*) echo "$(dim '      A required field is missing — oauthClients[0].issuer is the usual one.')" ;;
          *CSINH2002E*) echo "$(dim '      Duplicate displayName or externalId.')" ;;
        esac
        ;;
    esac
  done
}

delete_agents() {
  local i name role found any=false
  for i in $(seq 0 $((CLIENT_COUNT - 1))); do
    role=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].role")
    [ "$role" = "agent" ] || continue
    name=$(printf '%s' "$CLIENTS_JSON" | jq -r ".[$i].name")

    if [ "$any" = false ]; then
      echo
      echo "$(yellow 'Deleting') $(dim "agent records from ${TENANT_URL}/v1.0/Agents")"
      any=true
    fi

    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim '(dry-run) would DELETE /v1.0/Agents/<id>')"
      continue
    fi

    if ! found=$(find_agent "$name") || [ -z "$found" ]; then
      warn "$name" "$(dim 'no agent record — nothing to delete')"
      continue
    fi
    _split_resp "$(agents_api DELETE "/v1.0/Agents/$found")"
    case "$RESP_STATUS" in
      200|204) ok   "$name" "$(dim "agent record deleted (id=$found)")" ;;
      404)     warn "$name" "$(dim 'already gone')" ;;
      *)       fail "$name" "HTTP $RESP_STATUS" ;;
    esac
  done
}

write_back() {
  # Either half can have something to write: the clients created this run, or
  # an agent record created against a client that already existed.
  [ "${#CREATED[@]}" -gt 0 ] || [ "${#AGENTS_CREATED[@]}" -gt 0 ] || return 0

  echo
  echo "$(dim 'Credentials') $(dim "-> $(basename "$PDV")")"

  local entry name cid secret id_key secret_key updated=0
  local tmp; tmp="$(mktemp)"
  cp "$PDV" "$tmp"

  # Guarded: under `set -u` an empty array expansion aborts the function, which
  # would skip the agent write-back below on a run that created no clients.
  for entry in ${CREATED[@]+"${CREATED[@]}"}; do
    name="$(printf '%s' "$entry" | cut -f1)"
    cid="$(printf '%s' "$entry" | cut -f2)"
    secret="$(printf '%s' "$entry" | cut -f3)"

    id_key=$(printf '%s' "$CLIENTS_JSON" | jq -r --arg n "$name" '.[] | select(.name==$n) | .pdv_id_key')
    secret_key=$(printf '%s' "$CLIENTS_JSON" | jq -r --arg n "$name" '.[] | select(.name==$n) | .pdv_secret_key')
    [ -n "$id_key" ] || { ok "$name" "$(dim 'no write-back configured')"; continue; }

    if [ -z "$cid" ]; then
      warn "$name" "$(dim 'no client_id read back — not written')"
      continue
    fi
    # A client_id without its secret cannot authenticate; writing half the pair
    # would produce a config that fails at the token endpoint instead of here.
    if [ -z "$secret" ]; then
      warn "$name" "$(dim "client_id known but secret not returned — set $secret_key by hand from the console")"
    fi

    jq --arg ik "$id_key" --arg iv "$cid" \
       --arg sk "$secret_key" --arg sv "$secret" '
      .variables[$ik] = $iv
      | if $sv == "" then . else .variables[$sk] = $sv end' "$tmp" > "$tmp.new" \
      && mv "$tmp.new" "$tmp"
    ok "$name" "$(dim "$id_key${secret:+ + $secret_key}")"
    updated=$((updated + 1))
  done

  # Save the registry id for the gateway and status script.
  local aentry aname aid
  for aentry in ${AGENTS_CREATED[@]+"${AGENTS_CREATED[@]}"}; do
    aname="$(printf '%s' "$aentry" | cut -f1)"
    aid="$(printf '%s' "$aentry" | cut -f2)"
    [ -n "$aid" ] || continue
    jq --arg v "$aid" '.variables.VERIFY_AGENT_ID = $v' "$tmp" > "$tmp.new" \
      && mv "$tmp.new" "$tmp"
    ok "$aname" "$(dim 'VERIFY_AGENT_ID')"
    updated=$((updated + 1))
  done

  if [ "$updated" -gt 0 ]; then
    # Only now overwrite the real file, so a failure part-way leaves it intact.
    mv "$tmp" "$PDV"
  else
    rm -f "$tmp"
  fi

  write_back_reader
}

# Save registry-client credentials in .env.verify, which restart.sh loads.
# Replace existing assignments after re-provisioning to avoid stale credentials.
write_back_reader() {
  [ -n "$READER_CREATED" ] || [ -n "$OPERATOR_CREATED" ] || return 0
  local envf="$DEMO_DIR/.env.verify"

  if [ ! -f "$envf" ]; then
    warn ".env.verify" "$(dim 'not present — store these yourself')"
    [ -n "$READER_CREATED" ] && \
      echo "$(dim "      VERIFY_AGENT_READER_CLIENT_ID=$(printf '%s' "$READER_CREATED" | cut -f1)")"
    [ -n "$OPERATOR_CREATED" ] && \
      echo "$(dim "      VERIFY_AGENT_OPERATOR_CLIENT_ID=$(printf '%s' "$OPERATOR_CREATED" | cut -f1)")"
    echo "$(dim '      (secrets are shown in the Verify console under Security -> API access)')"
    return 0
  fi

  _append_pair() {
    local var_prefix="$1" pair="$2" label="$3" ent="$4" who="$5"
    [ -n "$pair" ] || return 0
    local cid secret
    cid="$(printf '%s' "$pair" | cut -f1)"
    secret="$(printf '%s' "$pair" | cut -f2)"
    local existing_id
    existing_id=$(sed -n "s/^${var_prefix}_CLIENT_ID=//p" "$envf" | tail -1)
    if [ -n "$existing_id" ]; then
      if [ "$existing_id" = "$cid" ]; then
        ok "$(basename "$envf")" "$(dim "${label} client already current")"
        return 0
      fi
      # Replace stale credentials after re-provisioning.
      local tmpf
      tmpf="$(mktemp)"
      sed -e "s|^${var_prefix}_CLIENT_ID=.*|${var_prefix}_CLIENT_ID=${cid}|" \
          -e "s|^${var_prefix}_CLIENT_SECRET=.*|${var_prefix}_CLIENT_SECRET=${secret}|" \
          "$envf" > "$tmpf" && mv "$tmpf" "$envf"
      warn "$(basename "$envf")" "$(dim "${label} client id changed — updated in place")"
      echo "$(dim "      was $existing_id")"
      echo "$(dim "      now $cid")"
      return 0
    fi
    {
      printf '\n'
      printf '# ---------------------------------------------------------------------------\n'
      printf '# Agent-status %s (scenario 14) — written by verify/import-verify-clients.sh\n' "$label"
      printf '# ---------------------------------------------------------------------------\n'
      printf '# Holds exactly one entitlement: %s\n' "$ent"
      printf '# Used by: %s\n' "$who"
      printf '%s_CLIENT_ID=%s\n' "$var_prefix" "$cid"
      printf '%s_CLIENT_SECRET=%s\n' "$var_prefix" "$secret"
    } >> "$envf"
    ok "$(basename "$envf")" "$(dim "${var_prefix}_CLIENT_ID + _SECRET appended")"
  }

  # Save separate reader and status-operator credentials.
  _append_pair VERIFY_AGENT_READER "$READER_CREATED" \
    "reader" "readAgents" \
    "the GATEWAY, on the request path (agent-status plugin)"
  _append_pair VERIFY_AGENT_OPERATOR "$OPERATOR_CREATED" \
    "operator" "manageAgentStatus" \
    "verify/set-agent-status.sh and a human admin flipping status"

  if [ -n "$OPERATOR_CREATED" ] || [ -n "$READER_CREATED" ]; then
    echo "$(dim '      The admin pair stays PROVISIONING-ONLY: nothing on the demo path reads it.')"
  fi
}


# ==========================================================================
# main
# ==========================================================================
echo
echo "$(dim 'tenant  ')" "$TENANT_URL"
echo "$(dim 'source  ')" "$CSV ($CLIENT_COUNT clients)"
echo "$(dim 'template')" "$TEMPLATE_ID"
if [ "$DRY_RUN" = true ]; then
  echo "$(dim 'mode    ')" "$(yellow 'dry-run — no requests will be sent')"
fi

if [ "$DRY_RUN" = false ]; then
  get_token
  resolve_scim_names
else
  # Dry-run cannot discover SCIM names; report the display-name fallback.
  echo "$(dim 'note    ')" "$(yellow 'claim mappers below assume scimName == claim name (unverifiable offline)')"
fi

if [ "$DISCOVER_ONLY" = true ]; then
  [ "$DRY_RUN" = true ] && die "--discover reads the tenant; it cannot be combined with --dry-run"
  discover
  echo
  echo "$(dim 'Discovery only — nothing was created.')"
  exit 0
fi

if [ "$DO_DELETE" = true ]; then
  # Agent records first: they reference the OAuth clients, and a dangling
  # reference is harder to reason about than an orphaned record.
  delete_agents
  delete_status_clients
  delete_clients
  # After the clients: the purpose is only deletable once nothing references it.
  if [ "$DO_PURPOSE" = true ]; then
    delete_purpose
  fi
else
  # Before the clients. The exchange client's tokenRequestMap names this purpose,
  # and a grant against a purpose that does not exist fails at DPCM.
  if [ "$DO_PURPOSE" = true ]; then
    create_purpose
  fi
  create_clients
  # After the clients: the registry record associates a client that must exist.
  create_agents
  # The gateway's own least-privilege credential for reading that record.
  create_status_clients
  if [ "$WRITE_BACK" = true ]; then
    write_back
  fi
fi

echo
if [ "$DRY_RUN" = true ]; then
  echo "$(dim 'Dry run only — nothing was sent to the tenant.')"
  echo "$(dim 'Claim mappers used the display name as the scimName; the real run resolves')"
  echo "$(dim 'it from the tenant, which can differ (gh_permissions -> ghpermissions).')"
elif [ "$DO_DELETE" = false ]; then
  echo "$(green 'Done.') Confirm the claims actually reach a token:"
  echo "  $(dim './mint-verify-token.sh alice | cut -d. -f2 | base64 -d 2>/dev/null | jq .')"
  echo "  $(dim './verify-ibm-verify-token-exchange.sh')"
  echo
  echo "$(dim 'Expect roles/permissions/teams/gh_permissions as ARRAYS with a trailing "".')"
  echo "$(dim 'A scalar or missing claim means a mapper did not resolve — check --discover.')"

  if [ "${#NEEDS_ENTITLEMENT[@]}" -gt 0 ]; then
    echo
    echo "$(yellow 'NOT ENTITLED') $(dim '— these clients cannot mint yet:')"
    for entry in "${NEEDS_ENTITLEMENT[@]}"; do echo "  $(dim "• $entry")"; done
    echo
    if [ "$DO_ENTITLE" = false ]; then
      echo "$(dim '  Skipped because --no-entitle was passed. Re-run without it, or grant')"
      echo "$(dim '  access in the console under Applications -> <client> -> Entitlements.')"
    else
      echo "$(dim '  The grant failed — see the error above. Until it succeeds the password')"
      echo "$(dim '  grant returns CSIAQ0279E ("Only entitled users can single sign-on").')"
      echo "$(dim '  Retry, or set it in the console: Applications -> <client> -> Entitlements.')"
    fi
  fi
  gw=$(printf '%s' "$CLIENTS_JSON" | jq -r '.[] | select(.role=="exchange") | .name' | head -1)
  if [ -n "$gw" ] && [ "${#CREATED[@]}" -gt 0 ]; then
    for entry in "${CREATED[@]}"; do
      if [ "$(printf '%s' "$entry" | cut -f1)" = "$gw" ]; then
        echo
        echo "$(dim 'policy-verify-opa.yaml picks this up automatically — it is rendered from')"
        echo "$(dim 'its .tmpl by render-verify-config.sh on every Verify run of restart.sh.')"
        echo "  $(dim "new exchange client_id: $(printf '%s' "$entry" | cut -f2)")"
      fi
    done
  fi
fi
