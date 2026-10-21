#!/usr/bin/env bash
# Provision the demo's OAuth clients into an IBM Verify tenant from
# verify/clients.csv, using keycloak/realm-export.json as the model.
#
# Sibling of import-verify-users.sh: that script creates the four personas, this
# one creates the clients that turn their attributes into token claims. RUN THE
# USER IMPORTER FIRST — the default entitlement model grants each persona
# sign-on access by SCIM id, so the users must already exist. Together
# they close decision D5 in
# docs/brainstorms/2026-08-31-ibm-verify-idp-requirements.md ("tenant setup is
# documented, not automated") — this half is the part verify/README.md still
# listed as manual: "It also does not create the two OAuth clients, enable ROPC,
# or set the JWT access-token format."
#
# Usage:
#   ./import-verify-clients.sh                  # create the clients
#   ./import-verify-clients.sh --dry-run        # print the payloads, send nothing
#   ./import-verify-clients.sh --discover       # show tenant facts, create nothing
#   ./import-verify-clients.sh --csv other.csv  # a different client source
#   ./import-verify-clients.sh --no-write-back  # do not touch post_deploy_variables.json
#   ./import-verify-clients.sh --all-users      # entitle ALL tenant users, not just the personas
#   ./import-verify-clients.sh --no-entitle     # skip entitlement entirely
#   ./import-verify-clients.sh --no-purpose     # do not create the DPCM consent purpose
#   ./import-verify-clients.sh --delete         # remove the CSV's clients
#
# Requires: curl, jq, python3 (CSV parsing only — no third-party packages).
#
# ---------------------------------------------------------------------------
# The admin API client needs one more entitlement than the user importer
# ---------------------------------------------------------------------------
# The Applications API is entitlement-gated per endpoint, like the Users API:
#
#   manageAppAccessAdmin  ("Manage application lifecycle")  -> POST/GET/DELETE
#                                                              /v1.0/applications
#
# import-verify-users.sh needs manageUsers + manageAttributes. If you built that
# admin client already, ADD manageAppAccessAdmin to it — a 403 here with a valid
# token means exactly that entitlement is missing. Credentials come from
# .env.verify (gitignored) as VERIFY_ADMIN_CLIENT_ID / VERIFY_ADMIN_CLIENT_SECRET.
#
# ---------------------------------------------------------------------------
# Five field-level facts, all confirmed against a live tenant
# ---------------------------------------------------------------------------
# These are the things that cost time to discover; the API reference documents
# none of them completely. Each was verified by creating and deleting a throwaway
# application on praxis-1.verify.ibm.com.
#
# 1. templateId is "998", not "0001". "0001" circulates in community examples
#    and is wrong here; every custom OIDC app on the tenant uses 998. There is
#    no documented enum, so --discover reads the value off the tenant's own
#    applications rather than trusting this default.
#
# 2. accessTokenType (NOT accessTokenFormat) selects JWT, and setting it to
#    "jwt" REQUIRES a signing algorithm or the create fails with:
#      CSIAQ0257 A JSON Web Token (JWT) access token type requires one of the
#                following signing algorithms: [RS256, ...]
#    The field that satisfies it is providers.oidc.properties.idTokenSigningAlg.
#    That name reads like it should only govern the ID token; it does not, and
#    the GET response omits it entirely, so you cannot discover it by reading an
#    existing app back. Without it every create 400s.
#
# 3. Grant types are the STRINGS "true"/"false", not JSON booleans.
#
# 3a. Enabling grantTypes.tokenExchange REQUIRES subjectTokenTypes, or the
#    create fails with:
#      CSIAQ0377 At least one subject token type is required.
#    It lives at providers.oidc.properties.additionalConfig.subjectTokenTypes
#    (the same additionalConfig that carries useUserDefaultEntitlements), NOT
#    under providers.oidc.token where the other token settings are. Unlike
#    idTokenSigningAlg it DOES read back on GET, so --discover can show it.
#    The tenant supplies no default: an app with tokenExchange off reads back
#    with the field absent entirely. Set alongside it is requestedTokenTypes,
#    the mirror field for what the exchange may mint.
#
# 4. Claim mappers are CELx functions, not sourceId references. The API
#    reference describes providers.oidc.token.attributeMappings[] as
#    JWTAttributeMapBean requiring `sourceId` + `targetName`, which implies
#    mapping by attribute ID. The tenant's working clients use a different and
#    undocumented shape — { targetName, function: { custom: <CELx> } } — and
#    that CELx calls user.getCustomValues(<scimName>). See below.
#
# 5. The CONSENT request mapping is a DIFFERENT and flatter shape than the
#    claim mappers in 4, which is the easy mistake here. It lives at
#    providers.oidc.properties.additionalConfig.tokenRequestMap[] and its
#    entries are { name, custom } — the CELx sits directly on the entry, with
#    NO `function` wrapper and no `targetName`. `name` is the request PARAMETER
#    being rewritten ("scope"), not a claim.
#
#    The tenant runs consentType "dpcm" (Data Privacy & Consent Management),
#    so an exchange that narrows a token to an `audience` needs a consent
#    grant for that audience. The mapping prepends an auto-granted purpose
#    naming the requested audience onto the request's scope, then concatenates
#    the real scope and authorization_details so nothing is lost. autoGrant
#    keeps it non-interactive; the purpose id must match the `purpose=` that
#    verify-ibm-verify-token-exchange.sh sends (P4AUD —
#    VERIFY_CONSENT_PURPOSE_ID overrides both the payload and the --discover
#    check). Confirmed on praxis-2: praxis-gateway, the only token-exchange
#    client, is the only one of five applications carrying the field, so the
#    script sets it only when token_exchange is on. consentType itself is
#    tenant-wide and NOT managed here — --discover reports it.
#
# 4a. ...and the purpose must EXIST before the client that grants it
#
#    The tokenRequestMap names a purpose id; it does not define one. The purpose
#    is a separate tenant resource under a DIFFERENT API base
#    (/config/v1.0/privacy/purposes, not /v1.0/...), and this script now creates
#    it — it was the last piece of tenant setup left manual, and its absence is
#    hard to diagnose: the clients all create cleanly and the failure surfaces
#    only at exchange time, from DPCM, as a consent error.
#
#    Two things about that API are worth knowing before editing it:
#
#      - POST always creates a DRAFT. The payload's `state` is ignored on
#        create: the purpose reads back state=0/version=0/hasDraft=true, and a
#        draft cannot be consented against. Publishing is a PATCH of the
#        VERSIONED resource:
#
#          PATCH /config/v1.0/privacy/purposes/<id>/<version>
#          {"op": "replace", "path": "state", "value": 1}
#
#        Three dead ends worth not repeating, all seen on a live tenant: a PUT
#        or PATCH of the UNVERSIONED item means "create/update a draft", so it
#        fails 403 CSIBT0024E ("Only one draft version for purpose is allowed")
#        once a draft exists; state:1 in a PUT body is accepted (204) and
#        silently does nothing; and `path` is the bare "state", not "/state"
#        (CSIBT0026E) with the body a single object, not an RFC 6902 array.
#        So create is POST-then-PATCH, and create_purpose() re-reads afterwards
#        to confirm an activeVersion rather than trusting the 201.
#      - A wrong path under this base returns HTTP 200 with an HTML
#        login-redirect body, not a 404. api_dpcm() therefore sniffs the body and
#        maps that to a synthetic 000; without it a typo reads as success.
#
#    An existing ACTIVE purpose is left untouched — republishing bumps the
#    version and invalidates consents already granted against it. A leftover
#    draft is published rather than reported as present. --no-purpose skips the
#    whole step; --delete removes the purpose after the clients, since it cannot
#    go while something still references it.
#
#    Mirrored from P4AUD as praxis-2 defines it: description "support
#    request-scoped aud", defaultConsentDuration 365, tags request|aud|scope,
#    category default, accessTypes [default], no attributes. Each is overridable
#    (VERIFY_CONSENT_PURPOSE_*) so a tenant with its own wording does not need an
#    edit here.
#
# ---------------------------------------------------------------------------
# THE EMPTY-STRING PADDING IS GONE — it used to live HERE, not in the user data
# ---------------------------------------------------------------------------
# Historical note, because this pad is described in several places and it matters
# which one actually minted it. The mappers below used to append `+ ['']`:
#
#   The tenant stored alice's roles as ["engineer"] — UNPADDED.
#   Her minted token carried  roles: ["engineer", ""] — PADDED.
#
# The pad was CLIENT config, injected by the CELx mapper, never in the SCIM user
# record. It existed because Praxis's standard claim mapper read
# roles/teams/permissions via Value::as_array (claim_map.rs:222,248), which
# returns None for a JSON scalar — so a single-valued persona got an EMPTY
# subject.roles, require(role.hr) failed, and it presented as a policy deny
# rather than the config fault it was. The accepted cost was that "" became a
# real set member and appeared in audit records and X-Policy-* output.
#
# The `ibmverify` claim-mapper preset fixes it at the source: it wraps a JSON
# scalar into a one-element vec before the structured fields are read. The policy
# selects it with `claim_mapper: ibmverify` on jwt-user and jwt-client
# (policy-verify-opa.yaml.tmpl), so SET_CEL below no longer pads.
#
# Two consequences. Clients created by an OLDER copy of this script still carry
# padded mappers on the tenant — re-run this script to overwrite them, since the
# mapper is what rebuilds the array. And pointing a gateway WITHOUT the preset at
# unpadded mappers reintroduces the silent-empty-roles failure.
#
# ONE CLAIM WAS ALWAYS EXEMPT: `manager`. It is not a custom attribute at all — it is the
# SCIM EnterpriseUser manager relationship, mapped with getManager().userName,
# which yields a scalar string. Its consumer is
# require_approval(from: claim.manager) in policy-verify-opa.yaml, which passes
# the value to CIBA as the login_hint naming the human approver, so padding it
# would break exactly what the pad exists to protect. See MANAGER_CEL below.
#
# ---------------------------------------------------------------------------
# getCustomValues() takes the scimName, which is not always the display name
# ---------------------------------------------------------------------------
# The CELx calls user.getCustomValues("<scimName>"). On this tenant the
# gh_permissions attribute has scimName "ghpermissions" — no underscore — so a
# mapper written against the display name silently yields no values, and
# scenario 4's exchange loses its permissions claim with no error anywhere.
#
# This script therefore RESOLVES each claim's scimName from /v1.0/attributes at
# run time instead of assuming name == scimName. Run --discover to see the
# mapping it will use.
#
# ---------------------------------------------------------------------------
# Application entitlement — the step that makes ROPC actually work
# ---------------------------------------------------------------------------
# Creating the application is NOT sufficient to mint. A client with correct
# grants, JWT tokens and claim mappers still rejects every password grant with:
#
#   CSIAQ0279E Only entitled users can single sign-on to the application.
#              You must request for application access.
#
# Application entitlement is a SEPARATE resource, not a field on the application:
#
#   POST /v1.0/owner/applications/{id}/entitlements
#   { "birthRightAccess": <bool>, "requestAccess": <bool>,
#     "additions": [ { "assignee": {"subjectId": <scim id>,
#                                   "subjectType": "user"},
#                      "grantType": "BRT" } ] }
#
# Entitlement: manageAppAccessAdmin (which this script already needs) or
# manageAppAccessOwner. GET on the same path reads the current state back.
#
# This is why it cannot be found by diffing application JSON: `birthRightAccess`
# reads back as null on GET /v1.0/applications/{id} — write-only there, the same
# trap as idTokenSigningAlg — and the grants live under /v1.0/owner/... instead.
#
# TWO ACCESS MODELS, both verified on the live tenant:
#
#   explicit (default here)  birthRightAccess=false + one addition per persona.
#                            Only the named users may sign on. This is how the
#                            owner's praxis-identity-1 is already configured
#                            (alice, bob, charlie, eve, each grantType BRT).
#                            Verified: alice mints, bob is denied.
#
#   birthright (--all-users) birthRightAccess=true. Every user in the tenant is
#                            entitled by default — the console's "Automatic
#                            access for all users and groups". Fewer calls, no
#                            SCIM lookups, but it grants tenant-wide.
#
# Explicit is the default because it matches both the existing tenant and the
# demo's own argument: four personas whose differences are the point. A client
# any user can mint from undercuts eve-vs-bob. Use --all-users on a throwaway
# tenant where that does not matter.
#
# BOTH role=mint AND role=exchange need this. The exchange was long assumed not
# to, on the reasoning that nobody ever authenticates to it — but an RFC 8693
# exchange carries the SUBJECT's identity, and Verify checks that user's
# entitlement against the exchange application too. Without it the mint leg
# succeeds and the exchange leg fails with CSIAQ0279E, which reads like a
# token-exchange feature problem rather than an entitlement one.
#
# Verified: the reference tenant's working praxis-sts-1 carries
# birthRightAccess=true; a freshly created one with no entitlement is denied,
# and granting the four personas makes the exchange succeed immediately.
#
# role=audience genuinely needs none: those are audience strings, and nothing
# ever presents a user to them.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CSV="$SCRIPT_DIR/clients.csv"
DRY_RUN=false
DO_DELETE=false
DISCOVER_ONLY=false
WRITE_BACK=true
# Entitlement model for role=mint clients. Explicit per-user grants by default;
# --all-users switches to tenant-wide birthright access. --no-entitle skips it
# entirely for a tenant that manages application access out of band.
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
# The purpose is a tenant resource in its own right, created before the clients
# that reference it (see "the purpose must exist first" in the header). These
# mirror P4AUD as praxis-2 defines it; --discover reports any drift.
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
    # Print just the synopsis (down to the "Requires:" line), not the whole
    # rationale essay in the header.
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

# --- CSV -> JSON ----------------------------------------------------------
# Parsed with python3's csv module rather than IFS=, read: it handles quoting
# and CRLF correctly, and it lets the '##' comment convention in clients.csv
# work. Columns are read BY HEADER NAME, so the CSV stays reorderable.
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
    # Verify rejects an application with every grant type disabled:
    #   CSIAQ0032 Grant type information is required.
    # Catch it here so the message names the row rather than surfacing as a raw
    # API error four requests later.
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

# --- claim mappers --------------------------------------------------------
# The CELx body for one set-valued claim. %s is the scimName that
# user.getCustomValues() looks up — NOT necessarily the display name.
#
# This used to append `+ ['']` to force array shape at N=1. The `ibmverify`
# claim-mapper preset now wraps a scalar into a one-element vec on the engine
# side, so the pad is gone — see the header. The null guard stays: an attribute
# the user simply does not have yields null, and the claim should be [] rather
# than absent.
SET_CEL='statements:
  - context: values := user.getCustomValues("%s")
  - context: "safeValues := context.values == null ? [] : context.values"
  - return: context.safeValues'

# ---------------------------------------------------------------------------
# `manager` is mapped from a RELATIONSHIP, not from a custom attribute
# ---------------------------------------------------------------------------
# Every claim above reads a custom attribute through getCustomValues(). `manager`
# does not, and cannot: on this tenant it is the standard SCIM EnterpriseUser
# manager reference, whose stored value is the manager's SCIM **id**. The mapper
# therefore traverses the reference and reads the userName off the user it
# resolves to:
#
#   statements:
#     - context: manager := user.getManager()
#     - return: context.manager.userName
#
# Three things follow, all of which make it unlike the mappers above:
#
#   - It takes NO scimName. The %s-style substitution the others use does not
#     apply, so this is a literal, not a printf template.
#   - It returns a SCALAR string ("alice"), which is what
#     require_approval(from: claim.manager) in policy-verify-opa.yaml needs — it
#     hands the value to CIBA as the login_hint naming the human approver. An
#     array ["alice"] would be unusable there, which is why this claim is mapped
#     by MANAGER_CEL and never went through the set mapper.
#   - There is nothing to resolve or validate against /v1.0/attributes, so
#     resolve_scim_names() skips it. A missing manager RELATIONSHIP is a user-data
#     problem that import-verify-users.sh reports, not a mapper problem.
#
# Verified on the live tenant: bob's record carries
#   enterprise:2.0:User.manager = { value: "<alice's id>", $ref: ... }
# and the tenant's own manager_uid attribute is sourced from that same
# manager.value — confirming the relationship is the source of truth.
MANAGER_CEL='statements:
  - context: manager := user.getManager()
  - return: context.manager.userName'

# Claims mapped from something other than a custom attribute, with the CELx each
# one uses. Keep in sync with import-verify-users.sh, which sets the relationship
# these read: that script decides what is STORED, this one what reaches the
# TOKEN, and a disagreement means the data is right and the claim is wrong.
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
  # Unresolved. On a real run resolve_scim_names() has already made this fatal,
  # so this is the --dry-run path: use the display name, which is correct for
  # every claim whose scimName matches it, and is reported as an assumption.
  printf '%s' "$claim"
}

# Read /v1.0/attributes once and record each claim's scimName. A claim whose
# attribute does not exist is fatal: the mapper would be created successfully
# and then silently yield nothing, which surfaces as a policy deny.
resolve_scim_names() {
  local claims attrs_json
  # Relationship claims (manager) are excluded: they are not custom attributes,
  # so /v1.0/attributes has no entry for them and the not-found branch below
  # would kill an otherwise correct run.
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
    # The endpoint returns a bare array on this tenant; tolerate a wrapped
    # shape too so a differently-versioned tenant does not silently resolve
    # every claim to its fallback.
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
    # A relationship claim (manager) is mapped by traversal and takes no
    # scimName; everything else reads a custom attribute through the set
    # mapper. See RELATIONSHIP_CLAIMS.
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
          # `sso` is required even for a pure OIDC app. userOptions:"oidc" is
          # what the tenant'"'"'s own working clients carry, and it satisfies the
          # requirement without inventing a domainName.
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
              # REQUIRED whenever accessTokenType is "jwt", despite the name
              # suggesting it only governs the ID token. Omit it and every
              # create fails with CSIAQ0257. See the script header.
              idTokenSigningAlg: $alg,
              doNotGenerateClientSecret: false,
              additionalConfig: ({
                # Without this, ROPC on a freshly created client fails with
                #   CSIAQ0279E Only entitled users can single sign-on to the
                #              application. You must request for application access.
                # even though the client, its grants and its mappers are all
                # correct — Verify gates sign-on on per-user application
                # entitlement. `true` means "every user in the tenant may use
                # this client", which is what the demo minting client needs and
                # what the tenant version already carries.
                #
                # Scoped to the minting client: this flag is about the
                # interactive sign-on default, and only role=mint is signed in
                # to directly. The exchange client needs application
                # ENTITLEMENT (granted separately, below) but not this default
                # — the audience placeholders need neither.
                useUserDefaultEntitlements: ($c.role == "mint")
                # Enabling the tokenExchange grant makes these REQUIRED; without
                # subjectTokenTypes the create fails with:
                #   CSIAQ0377 At least one subject token type is required.
                # It is the token type the exchange ACCEPTS as its subject_token,
                # and it has no default — github-api, whose tokenExchange is off,
                # reads back with the field absent, so the tenant does not fill
                # it in. Hence set it only when the grant is on.
                #
                # requestedTokenTypes is the mirror field (what the exchange may
                # MINT). The working praxis-sts-1 on the reference tenant carries
                # both, each holding just access_token — exactly what
                # verify-ibm-verify-token-exchange.sh sends as
                # subject_token_type and expects to get back.
              }
              + (if $c.token_exchange then {
                  subjectTokenTypes:   ["urn:ietf:params:oauth:token-type:access_token"],
                  actorTokenTypes:   ["urn:ietf:params:oauth:token-type:access_token"],
                  requestedTokenTypes: ["urn:ietf:params:oauth:token-type:access_token"],
                  # Consent request mapping. The tenant runs consentType "dpcm"
                  # (Data Privacy & Consent Management), so an exchange that
                  # narrows a token to an `audience` needs a matching consent
                  # grant for that audience or DPCM has nothing to approve.
                  # This rewrites the request'"'"'s `scope` to PREPEND a purpose
                  # entry naming the requested audience, then concatenates the
                  # real scope and authorization_details so nothing is dropped.
                  #
                  # Three things to know about the shape:
                  #
                  #  - Entries are FLAT { name, custom } — the `custom` CELx sits
                  #    directly on the entry. This is NOT the attributeMappings
                  #    shape ({ targetName, function: { custom } }); reusing that
                  #    one here silently maps nothing.
                  #  - `name` is the request parameter being rewritten ("scope"),
                  #    not a claim name.
                  #  - The ternary guard matters: requestContext.getValue(
                  #    "audience") is "" on a plain client_credentials call, and
                  #    emitting a purpose with an empty audience makes DPCM
                  #    reject the request. Empty audience -> no purpose entry.
                  #
                  # autoGrant:true is what keeps the demo non-interactive: the
                  # purpose is granted as part of the exchange instead of
                  # queueing an approval. P4AUD is the tenant'"'"'s purpose id, and
                  # is the same value verify-ibm-verify-token-exchange.sh sends
                  # as `purpose=P4AUD` on the exchange call — the two must agree.
                  #
                  # Scoped to token_exchange clients: the audience placeholders
                  # and the minting client never narrow by audience, so a
                  # tokenRequestMap on them would be inert config. Confirmed
                  # against praxis-2, where praxis-gateway is the only one of the
                  # five applications carrying this field.
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
              # accessTokenType, NOT accessTokenFormat. Praxis validates the
              # access token as a JWT against the tenant JWKS, so "default"
              # (opaque) would fail at identity.
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

# ==========================================================================
# discovery
# ==========================================================================
# The two facts this script cannot safely assume: which template a custom OIDC
# app uses, and each claim'"'"'s scimName. Both are read off the tenant.
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
  # Reads back on GET, so unlike idTokenSigningAlg this one is discoverable.
  # Shown because consentType is a TENANT-WIDE setting the script does not
  # manage: if a tenant is not on "dpcm", the auto-granted purpose below is
  # meaningless and the audience-narrowing exchange needs rethinking.
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

# ==========================================================================
# consent purpose
# ==========================================================================
# The DPCM purpose the exchange client's tokenRequestMap auto-grants. It is a
# tenant resource, NOT part of the application, and it lives behind a different
# API than everything else this script touches:
#
#   /config/v1.0/privacy/purposes        POST, GET   (collection)
#   /config/v1.0/privacy/purposes/<id>   PUT, GET, DELETE
#
# Confirmed by OPTIONS on a live tenant. Note the shape: the base is
# /config/v1.0/..., not /v1.0/... like the Applications API, so it does NOT go
# through api() — see api_dpcm(). A wrong path here does not 404; the tenant
# serves an HTML login-redirect page with HTTP 200, which is why api_dpcm()
# checks the content type rather than trusting the status code.
#
# ---------------------------------------------------------------------------
# Create is two calls, because POST only ever creates a DRAFT
# ---------------------------------------------------------------------------
# A purpose is versioned, and POST always lands a draft regardless of what the
# payload says:
#
#   POST {... "state": 1 ...}  ->  201, then GET shows
#                                  state=0, version=0, activeVersion=null,
#                                  hasDraft=true
#
# A draft purpose exists but cannot be consented against, so the exchange would
# still fail — and it fails at DPCM, which reads as a consent problem rather
# than a provisioning one. The published tenant purpose reads back as
# state=1, version=1, activeVersion=1, hasDraft=false.
#
# Publishing is a PATCH of the VERSIONED item flipping state to 1 — see
# publish_purpose() for the exact call and the three shapes that do NOT work.
# create_purpose() therefore POSTs, reads the draft's version back, PATCHes, and
# only reports success once a further read shows an activeVersion.
PURPOSE_PATH="/config/v1.0/privacy/purposes"

# Like api(), but for the /config/v1.0 DPCM base and with one extra guard: an
# unknown path under this base returns HTTP 200 with an HTML login-redirect
# body instead of a 404, so a typo would otherwise look like success and then
# fail jq parsing further down. Maps that case to a synthetic 000.
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

# The create body. `state: 1` is sent even though POST ignores it: the PUT that
# publishes reuses this same payload, and a body that disagrees with itself
# between the two calls is worse than a field the first call drops.
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
      # No attributes: the purpose governs an audience, not a set of PII
      # attributes, so there is nothing to enumerate. An empty list is required
      # rather than omitted.
      attributes: [],
      customAttributes: []
    }'
}

# "<state>\t<activeVersion>\t<version>" for the purpose, or empty if it does not
# exist. All three matter: a draft left behind by a half-finished run exists but
# has activeVersion=null, and publishing it needs its version number for the
# PATCH path (see publish_purpose).
find_purpose() {
  _split_resp "$(api_dpcm GET "${PURPOSE_PATH}/${CONSENT_PURPOSE_ID}")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r '"\(.state // 0)\t\(.activeVersion // "")\t\(.version // 0)"'
}

# Publish the draft at version $1 by flipping its state to active.
#
# This is a PATCH of the VERSIONED resource, and neither half of that is
# guessable — both were established against a live tenant:
#
#   PATCH /config/v1.0/privacy/purposes/<id>/<version>
#   {"op": "replace", "path": "state", "value": 1}          -> 204
#
#   - The version belongs in the PATH. A PUT or PATCH of the unversioned item
#     is "create/update a draft", NOT publish: it answers 403 CSIBT0024E
#     ("Only one draft version for purpose is allowed") because a draft already
#     exists. Putting state:1 in a PUT body does nothing either — the PUT
#     returns 204 and the purpose stays state=0.
#   - `path` is the bare field name "state", not JSON-Pointer "/state" (which
#     the API rejects: CSIBT0026E, "Valid input is [state]"), and the body is a
#     single object, not the RFC 6902 array (which reports `op` missing).
#
# After this the purpose reads state=1, version=1, activeVersion=1,
# hasDraft=false — the shape a published purpose has.
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

  # Idempotent, like the client create: an existing ACTIVE purpose is left
  # alone. Overwriting it would bump the version and invalidate consents already
  # granted against it, which is not something a provisioning re-run should do.
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

# ==========================================================================
# clients
# ==========================================================================
# Look up an application by name -> "<id>\t<clientId>". Makes create idempotent
# and drives --delete. Filtered client-side: the search syntax for this endpoint
# is undocumented, and a wrong filter silently returns everything.
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

# name<TAB>id<TAB>secret for every client created in this run, consumed by
# write_back(). Kept in memory: secrets do not belong on disk outside the
# gitignored post_deploy_variables.json.
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
      # The application itself is left alone, but ENTITLEMENT is repaired: it
      # lives on a separate resource, and a tenant provisioned before the agent
      # existed has the exchange client entitled per-persona, which the agent
      # subject cannot satisfy (CSIAQ0279E). Re-running the importer should fix
      # that rather than requiring --delete of a working client.
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
        # A client users authenticate TO is gated on application entitlement,
        # which is a separate resource from the application itself. Grant it now
        # or the client cannot mint (CSIAQ0279E). See the script header.
        # Both mint AND exchange need entitlement. The exchange was long assumed
        # not to ("nobody authenticates to it"), but an RFC 8693 exchange carries
        # the SUBJECT's identity, so Verify checks that subject against the
        # exchange application as well — without it the exchange leg fails
        # CSIAQ0279E even though the mint leg works. Verified on a live tenant.
        # role=audience genuinely needs none: nothing ever presents a subject
        # to it.
        #
        # role=agent needs none of its OWN either — nothing authenticates TO the
        # agent's client. But see entitle_app: when an agent row exists, the
        # EXCHANGE client must be entitled by birthright rather than per-user,
        # because the agent is the exchange subject and is not a persona user.
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

  # --------------------------------------------------------------------------
  # The agent forces birthright on the EXCHANGE client
  # --------------------------------------------------------------------------
  # Application entitlement is checked against the exchange SUBJECT. The demo's
  # per-user model grants it to each persona by SCIM id, which works for bob /
  # alice / eve — and cannot work for the agent, which is an OAuth client, not
  # a user in the directory. There is no SCIM id to add.
  #
  # So when a role=agent row exists, the exchange client is entitled by
  # birthright (every principal in the tenant) instead. Without this, scenario
  # 14's delegate step fails with:
  #   CSIAQ0279E Only entitled users can single sign-on to the application.
  # while scenarios 01-13 pass, because their subjects ARE personas. Verified
  # on praxis-2: birthright on the exchange client fixes the agent exchange and
  # leaves all three persona exchanges working.
  #
  # Scoped deliberately: only the exchange client, and only when an agent is
  # being provisioned. The minting client keeps its explicit per-user grants,
  # which is what makes "only these four personas can sign on" demonstrable.
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

# ==========================================================================
# write-back
# ==========================================================================
# Verify GENERATES the client_id and client_secret, so unlike the Keycloak realm
# export nothing downstream can hardcode them. mint-verify-token.sh and
# verify-ibm-verify-token-exchange.sh both read them from
# post_deploy_variables.json, so a freshly provisioned tenant is only usable
# once they land there. That file is gitignored (it holds live credentials).
#
# policy-verify-opa.yaml needs no editing here: it is GENERATED from
# policy-verify-opa.yaml.tmpl by ../render-verify-config.sh, which reads the
# exchange client_id from GATEWAY_CLIENT_ID in this same file (or from
# $VERIFY_GATEWAY_CLIENT_ID). restart.sh renders it on every Verify run, so a
# write-back here is all that is needed for the new id to reach the gateway.
# ==========================================================================
# Agent Registry (scenario 14)
# ==========================================================================
# The second half of role=agent. The OAuth client above is what the agent
# AUTHENTICATES as; the Agent Registry record is what it IS to governance —
# display name, owner, tags, and a lifecycle status an admin flips in the
# console.
#
# Four tenant behaviors are load-bearing here. Each was verified against
# praxis-2 and each breaks the demo quietly if ignored:
#
#   1. CREATE ALWAYS LANDS IN `UNDER_REVIEW`. POST /v1.0/Agents ignores the
#      `status` field entirely — sending "ACTIVE" explicitly still stores
#      UNDER_REVIEW (measured on praxis-2; the brainstorm's finding E8 assumed
#      an explicit value was enough, and it is not). Only PUT honors a status
#      change. So create_agents() POSTs and then PROMOTES with a follow-up PUT,
#      and reports loudly if the promotion does not take — a demo whose agent
#      silently starts un-approved would look like the kill switch is stuck on.
#   2. `oauthClients[0].issuer` is REQUIRED (CSINH2100E otherwise) and is
#      tenant-specific: on praxis-2 it is the token issuer,
#      <tenant>/oauth2. Derived below, never hardcoded.
#   3. `oauthClients` is WRITE-ONLY. It reads back as null on GET and on LIST
#      even immediately after a 201/200 that accepted it. So association is
#      verified by the write's status code and NOT by reading it back; a
#      read-back check here would always "fail" against a correct tenant.
#   4. PUT is a FULL REPLACE. A PUT that omits description/tags/oauthClients
#      clears them. set_agent_status() therefore re-sends the whole record.
#
# Early Access: a tenant without Agent Registry answers 403/404 on
# /v1.0/Agents. That must not fail the client import, so every call here warns
# and continues rather than dying.

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

# --------------------------------------------------------------------------
# The gateway's own credential: a readAgents-only API client
# --------------------------------------------------------------------------
# The gateway must read /v1.0/Agents/{id} on the request path to enforce agent
# status. Handing it the admin API client for that would be wrong: that client
# carries ~40 entitlements including writeAgents and agentOwner, so a gateway
# compromise would mean an attacker could rewrite the very records that are
# supposed to govern it — and silently re-enable a suspended agent.
#
# So provisioning mints a dedicated API client holding exactly ONE entitlement,
# `readAgents`. Verified against praxis-2: with it the gateway can GET an agent
# record (200) and can do nothing else — PUT /v1.0/Agents is 403, POST
# /v2.0/Users is 403, GET /v1.0/applications is 403.
#
# The admin pair goes back to being provisioning-only, which is what the rest of
# this script already assumes.
#
# Two API details worth knowing:
#   - POST /v1.0/apiclients returns 201 with an EMPTY body, so the client has to
#     be found by name afterwards.
#   - the secret is not in the collection listing, only on
#     GET /v1.0/apiclients/{id}. Which is also why this is readable at all:
#     there is no "show secret once" semantics to miss.
READER_CLIENT_NAME="${READER_CLIENT_NAME:-praxis-agent-status-reader}"
# The OPERATOR credential: status changes only, used by
# verify/set-agent-status.sh (and by a human mid-demo). Deliberately a SECOND
# client rather than another entitlement on the reader above.
#
# Splitting them is the whole point. `manageAgentStatus` can flip an agent back
# to ACTIVE, so a gateway holding it could re-enable the agent its own policy
# just suspended — the kill switch would be its own bypass. Verified on
# praxis-2: the reader gets 403 on PUT /v1.0/Agents, and the operator gets 403
# on everything except a status change.
OPERATOR_CLIENT_NAME="${OPERATOR_CLIENT_NAME:-praxis-agent-status-operator}"

find_api_client() {
  local want="$1"
  _split_resp "$(api GET "/v1.0/apiclients?limit=200")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r --arg n "$want" \
    '[.apiClients[]? | select(.clientName==$n) | .id] | .[0] // empty'
}

# Creates an agent-status API client when absent and reads back its
# credentials. Takes the client name, the single entitlement it must hold, and
# the name of the global to stash "<client_id>\t<secret>" into.
#
# Parameterised rather than duplicated because the two clients differ in
# exactly one field, and a copy-paste pair would drift.
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
  # Indirect assignment: bash 3.2 (stock macOS) has no nameref, so this is the
  # portable form. Values are a tenant UUID and its secret, neither of which
  # can contain a quote, and both come from jq rather than from user input.
  eval "$out_var=\"\$cid\"\$'\\t'\"\$secret\""
}

# Both agent-status credentials. The split is a security boundary, not tidiness:
#
#   reader   readAgents         the GATEWAY, on the request path. Can read an
#                               agent record and nothing else.
#   operator manageAgentStatus  verify/set-agent-status.sh and a human admin.
#                               Can change status and nothing else — not even
#                               rename the agent (403 CSINH2507E).
#
# Neither can do the other's job, so a compromised gateway cannot undo a
# suspension and the operator credential cannot be used to read traffic.
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

  # The Agent Registry id. Not a credential — it is the governance handle the
  # gateway's agent-status plugin and verify/set-agent-status.sh both read, so
  # it belongs next to the client ids rather than in .env.verify.
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

# The reader client's id and SECRET.
#
# Deliberately not post_deploy_variables.json: that file holds generated ids and
# is handed around, whereas this is a live credential the gateway process reads
# at runtime. .env.verify is where this demo already keeps those, and restart.sh
# sources it into the gateway's environment.
#
# Appended rather than rewritten, and only when absent, so a hand-managed
# .env.verify is never clobbered.
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
      # The ids disagree. This is what a clean-slate re-provision produces: new
      # tenant clients, stale values here — and the stale ones will fail to
      # authenticate, which surfaces much later as a confusing gateway error.
      # Rewrite in place rather than appending a duplicate: a second
      # assignment of the same variable would silently win or lose depending on
      # sourcing order.
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

  # Two credentials, deliberately separate. Neither can do the other's job:
  # the reader cannot change status (403), the operator cannot read anything
  # else (403). So a compromised gateway cannot undo a suspension.
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
  # No tenant call, so scimNames cannot be resolved. Say so where the payloads
  # are about to be printed rather than letting getCustomValues("<display name>")
  # look authoritative.
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
