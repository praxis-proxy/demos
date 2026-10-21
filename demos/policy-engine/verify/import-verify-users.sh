#!/usr/bin/env bash
# Provision the demo personas into an IBM Verify tenant from verify/users.csv.
#
# This closes the gap left by decision D5 in
# docs/brainstorms/2026-08-31-ibm-verify-idp-requirements.md ("tenant setup is
# documented, not automated") for the part that is most tedious and most
# error-prone by hand: the four users, their four custom attributes, and the
# manager relationships between them.
#
# Usage:
#   ./import-verify-users.sh                    # create attrs + users
#   ./import-verify-users.sh --dry-run          # print the SCIM payloads, send nothing
#   ./import-verify-users.sh --attrs-only       # define the custom attributes, no users
#   ./import-verify-users.sh --users-only       # assume attributes already exist
#   ./import-verify-users.sh --csv other.csv    # a different user source
#   ./import-verify-users.sh --delete           # remove the CSV's users from the tenant
#
# Requires: curl, jq, python3 (CSV parsing only — no third-party packages).
#
# ---------------------------------------------------------------------------
# What this needs from the tenant, and why it is a SEPARATE client
# ---------------------------------------------------------------------------
# The Users and Attributes APIs authenticate with a Verify *API client* whose
# entitlements are checked per-endpoint — these are entitlements, not OAuth
# scopes:
#
#   manageUsers       (or manageUserGroups)  -> POST/DELETE /v2.0/Users
#   manageAttributes                         -> POST /v1.0/attributes
#
# Neither hr-copilot (HR_COPILOT_CLIENT_ID) nor the gateway exchange client
# (GATEWAY_CLIENT_ID) has them, and they should not: those two are in the demo's
# hot path, and a client that can mint alice's token should not also be able to
# rewrite alice's permissions. Create a third API client in
#   Security -> API access -> Add API client
# and put its credentials in .env.verify (gitignored) as:
#
#   VERIFY_ADMIN_CLIENT_ID=...
#   VERIFY_ADMIN_CLIENT_SECRET=...
#
# The tenant URL is derived from IBM_VERIFY_TOKEN_ENDPOINT in
# post_deploy_variables.json, so there is nothing else to configure.
#
# ---------------------------------------------------------------------------
# The empty-string padding is GONE — the engine handles scalars now
# ---------------------------------------------------------------------------
# Verify still serialises a custom attribute holding exactly one value as a JSON
# SCALAR, not a one-element array. This used to be load-bearing here: Praxis's
# standard claim mapper read roles/teams/permissions via Value::as_array, which
# returns None for a JSON string, so a single-role persona got an EMPTY
# subject.roles with no error raised, `require(role.hr)` failed, and the whole
# thing presented as a policy deny rather than the config fault it was. Every
# multi-valued attribute was therefore padded with a trailing "" to force array
# shape, at the known cost that "" became a real set member and showed up in
# audit records and X-Policy-* debug output.
#
# The `ibmverify` claim-mapper preset removes the reason for it: it wraps a JSON
# scalar into a one-element vec before the structured fields are read, so an
# unpadded single-valued attribute now maps correctly. The policy selects it with
#   claim_mapper: ibmverify
# on the jwt-user and jwt-client plugins (policy-verify-opa.yaml.tmpl).
#
# So the values sent below are unpadded, and the CELx mappers in
# import-verify-clients.sh no longer append `+ ['']` either. Both sides have to
# agree: a tenant whose clients still carry the old padded mappers will mint
# ["engineer", ""] no matter what this script stores, because the mapper rebuilds
# the array from getCustomValues(). Re-run import-verify-clients.sh after this.
#
# If you are pointing this at a gateway WITHOUT the ibmverify preset, the padding
# is load-bearing again — see git history for the version that appends it.
#
# `manager` is NOT one of these attributes and never was padded — it is not a
# custom attribute at all. See the next section.
#
# ---------------------------------------------------------------------------
# `manager` is a SCIM relationship, not a custom attribute
# ---------------------------------------------------------------------------
# The other four claims are custom attributes in customAttribute1..150 slots.
# `manager` is different in kind: it is the standard SCIM EnterpriseUser
# extension's manager reference,
#
#   "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User": {
#     "manager": { "value": "<SCIM id>", "$ref": "<.../Users/<id>>" }
#   }
#
# and its value is the manager's SCIM **id**, not their userName. The tenant
# generates $ref itself; only `value` is written.
#
# This matters because of what the token mapper does with it. The introspection
# mapper on the client is:
#
#   statements:
#     - context: manager := user.getManager()
#     - return: context.manager.userName
#
# getManager() FOLLOWS the reference above and returns the manager's user object,
# and the mapper reads .userName off it. So the claim is a scalar string
# ("alice") produced by a relationship traversal — there is no custom attribute
# holding it, and creating one would be dead weight the mapper never reads.
# (The tenant's own `manager_uid` attribute is sourced from
# ...enterprise:2.0:User:manager.value, i.e. from this same relationship.)
#
# TWO CONSEQUENCES for this script:
#
#   1. It cannot be set in the CREATE payload, because the manager's id does not
#      exist until that user is created. bob names alice, and if alice is created
#      after bob there is nothing to reference. So managers are a SECOND PASS
#      (link_managers) after every user exists, resolving userName -> id.
#
#   2. It is a PATCH, not a field: op=replace on
#      <enterprise schema>:manager. Verified on a live tenant — 204, and the
#      read-back carries the generated $ref. op=remove clears it.
#
# ---------------------------------------------------------------------------
# pwdReset: a REQUEST HEADER, not a payload field
# ---------------------------------------------------------------------------
# Verify sets pwdReset=true on every user created through the SCIM API — the
# "user must change password at next sign-in" flag. It is how Verify treats any
# admin-set password. The user is otherwise perfect, but ROPC refuses it:
#
#   CSIAQ0267E The password must be changed.
#
# which names neither the user nor the cause, so it reads like a bad password in
# users.csv or a broken client.
#
# The fix is a request header on POST /v2.0/Users:
#
#   usershouldnotneedtoresetpassword: true
#
# Verified: with it the create returns pwdReset=null and the password grant
# works immediately; without it, pwdReset=true and every mint fails.
#
# It is worth being explicit about WHY this is a header, because the natural
# assumption is that it must be a payload field somewhere. It is not, and the
# payload cannot express it — all of these were tried against a live tenant:
#
#   - pwdReset:false in the create body   -> 201, silently ignored
#   - PATCH pwdReset                      -> 400 CSIAI0174E (read-only; a PATCH
#                                            of `active` returns 204, so the
#                                            request shape was not the problem)
#   - PATCH password to a NEW value       -> 204, pwdReset STAYS true — an admin
#                                            write is itself a reset
#   - userCategory:"federated"            -> 400, and changes what the user is
#
# So there is no way to discover this from the payload or from reading a working
# user back: an already-fixed user and a header-created one look identical.
#
# create_users() also still reports any user that comes back with pwdReset=true,
# which now means the header was rejected or ignored (a tenant that does not
# honour it) rather than the normal state of affairs.

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CSV="$SCRIPT_DIR/users.csv"
DRY_RUN=false
DO_ATTRS=true
DO_USERS=true
DO_DELETE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=true ;;
    --attrs-only) DO_USERS=false ;;
    --users-only) DO_ATTRS=false ;;
    --delete)     DO_DELETE=true; DO_ATTRS=false ;;
    --csv)        CSV="${2:?--csv needs a path}"; shift ;;
    # Print just the synopsis (down to the "Requires:" line), not the whole
    # rationale essay in the header.
    -h|--help)    sed -n '2,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
[ -f "$CSV" ] || die "user source not found: $CSV"

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

The Users and Attributes APIs need an API client with the 'manageUsers' and
'manageAttributes' entitlements. This is deliberately NOT hr-copilot and NOT
the gateway exchange client — see the header of this script for why.

  1. Verify admin console -> Security -> API access -> Add API client
  2. Grant: "Manage users and groups" and "Manage attributes"
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
#
# The two APIs this script talks to do NOT share a media type, and getting it
# wrong is a 406 rather than a helpful error:
#
#   /v2.0/Users      SCIM  -> application/scim+json
#   /v1.0/attributes plain -> application/json
#
# The Attributes API rejects scim+json in Accept with "406 Not Acceptable"
# before it ever looks at the body, so send each endpoint the type it declares.
# api <METHOD> <PATH> [BODY] [EXTRA_HEADER]
# EXTRA_HEADER is passed through as one -H. Only create_users() uses it, for the
# pwdReset header documented in the header of this script.
api() {
  local method="$1" path="$2" body="${3:-}" extra_header="${4:-}"
  local ctype="application/json"
  case "$path" in
    /v2.0/*) ctype="application/scim+json; charset=utf-8" ;;
  esac
  local -a args=(-sS -o - -w $'\n%{http_code}' -X "$method" "${TENANT_URL}${path}"
    -H "Authorization: Bearer $ACCESS_TOKEN"
    -H "Accept: $ctype")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: $ctype" -d "$body")
  fi
  if [ -n "$extra_header" ]; then
    args+=(-H "$extra_header")
  fi
  curl "${args[@]}"
}

# Split "<body>\n<status>" from api() into the globals RESP_BODY / RESP_STATUS.
_split_resp() {
  RESP_STATUS="${1##*$'\n'}"
  RESP_BODY="${1%$'\n'*}"
}

# ==========================================================================
# 1. Custom attribute definitions
# ==========================================================================
# A custom attribute must exist in the TENANT SCHEMA before a user payload may
# carry it — an undefined attribute fails the create with a validation error
# rather than being created implicitly. Each definition claims one of the
# predefined customAttribute1..150 slots.
#
# datatype string[] is what keeps these multi-valued. The slot numbers are
# arbitrary but must be stable: changing one after users exist orphans the
# stored values.
#
# Verify's scimName validator accepts LETTERS ONLY — an underscore or hyphen is
# rejected with "CSIAI0096E The value <x> is not valid for attribute [scimName]"
# (a 400 that is NOT an "already exists" 400). So the display name and the
# scimName have to be allowed to differ: gh_permissions -> ghpermissions.
#
# The scimName is the operative one — the CELx claim mappers call
# user.getCustomValues("<scimName>"), and import-verify-clients.sh resolves it
# from the tenant rather than assuming name == scimName. Keep this in sync with
# that script and with verify/README.md.
#
# `manager` is deliberately NOT in this list: it is a SCIM relationship, not a
# custom attribute, and the client's mapper reaches it with getManager() rather
# than getCustomValues(). Adding it here would claim a slot nothing reads. See
# the "manager is a SCIM relationship" section in the header and link_managers().
#
# Format: displayName:slot:scimName
ATTRS=(
  "roles:customAttribute1:roles"
  "permissions:customAttribute2:permissions"
  "teams:customAttribute3:teams"
  "gh_permissions:customAttribute4:ghpermissions"
)

# The SCIM extension that carries the manager reference. Long enough, and used in
# enough places below, to be worth a name.
ENTERPRISE_SCHEMA="urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"

# --- CSV -> JSON ----------------------------------------------------------
# Parsed with python3's csv module rather than IFS=, read: it handles quoting
# and CRLF correctly, and it lets the '##' comment convention in users.csv work.
# Columns are read BY HEADER NAME, so the CSV stays reorderable and an operator
# can add a column without touching the field offsets here.
#
# Multi-valued cells are pipe-separated (see users.csv), and each list is sent as
# it reads — no trailing "" pad; see the header comment.
csv_json() {
  # Build "csvName=scimName,..." from ATTRS so the two never drift apart.
  local entry map=""
  for entry in "${ATTRS[@]}"; do
    map+="${entry%%:*}=${entry##*:},"
  done
  python3 - "$CSV" "${map%,}" <<'PY'
import csv, json, sys

REQUIRED = ["username", "email", "first_name", "last_name", "password"]

# `manager` is optional and single-valued: it names ONE userName, resolved to a
# SCIM id in a second pass (see link_managers in the shell below). It is not a
# custom attribute, so it is carried as a plain field rather than through
# ATTR_MAP — the client mapper returns getManager().userName, a scalar string.
OPTIONAL = ["manager"]

# Custom attributes, in the order they are emitted. The CSV column keeps the
# readable name (gh_permissions); the SCIM payload must use the tenant's
# scimName, which is letters-only (ghpermissions). The map arrives as
# "csvName=scimName,..." in argv[2] so ATTRS in the shell below stays the single
# source of truth for that pairing.
ATTR_MAP = [tuple(pair.split("=", 1)) for pair in sys.argv[2].split(",") if pair]

with open(sys.argv[1], newline="") as fh:
    # '##' lines are documentation, not data. Blank lines are skipped so the
    # file can be visually grouped.
    rows = [ln for ln in fh if not ln.lstrip().startswith("##") and ln.strip()]

reader = csv.DictReader(rows)
missing = [c for c in REQUIRED if c not in (reader.fieldnames or [])]
if missing:
    sys.exit(f"users.csv is missing required column(s): {', '.join(missing)}\n"
             f"found: {', '.join(reader.fieldnames or [])}")

out = []
seen = set()
for i, row in enumerate(reader, start=2):
    user = {k: (row.get(k) or "").strip() for k in REQUIRED + OPTIONAL}
    if not user["username"]:
        sys.exit(f"row {i}: empty username")
    if user["username"] in seen:
        sys.exit(f"row {i}: duplicate username {user['username']!r}")
    seen.add(user["username"])
    if not user["password"]:
        # Verify would mail a generated password to an @corp.com address that
        # does not resolve, so ROPC minting would then be impossible.
        sys.exit(f"row {i}: {user['username']} has no password; "
                 f"mint-verify-token.sh needs one to use the password grant")

    attrs = {}
    for name, scim in ATTR_MAP:
        raw = (row.get(name) or "").strip()
        # Sent unpadded. Verify still serialises a single value as a JSON scalar,
        # but the engine's `ibmverify` claim-mapper preset now wraps a scalar into
        # a one-element vec, so array shape no longer has to be forced here. See
        # the script header.
        attrs[scim] = [v.strip() for v in raw.split("|") if v.strip()]
    user["attributes"] = attrs

    # The manager cell names one userName. A pipe here is an operator assuming it
    # behaves like the multi-valued columns next to it; the reference can hold
    # exactly one id, so say so rather than silently taking the first.
    if "|" in user["manager"]:
        sys.exit(f"row {i}: {user['username']} has multiple managers "
                 f"({user['manager']!r}); the SCIM manager reference holds one "
                 f"user, and the claim becomes a single CIBA login_hint")
    if user["manager"] and user["manager"] == user["username"]:
        sys.exit(f"row {i}: {user['username']} is their own manager; "
                 f"require_approval would ask them to approve themselves")
    out.append(user)

# Managers are resolved by userName against the tenant, but a name that is simply
# misspelled here would resolve to nothing and be reported as a missing tenant
# user — misleading when the intended manager is right there in the CSV. Catch
# the in-file case now, where the row number is still available.
for u in out:
    if u["manager"] and u["manager"] not in seen:
        sys.exit(f"{u['username']}'s manager {u['manager']!r} is not a username "
                 f"in this file. A manager outside the CSV is legitimate — it "
                 f"just has to already exist on the tenant, so remove this check "
                 f"if that is what you mean.")

json.dump(out, sys.stdout)
PY
}

USERS_JSON="$(csv_json)" || die "failed to parse $CSV"
USER_COUNT=$(printf '%s' "$USERS_JSON" | jq 'length')

# Build the SCIM create payload for the user at index $1.
scim_payload() {
  printf '%s' "$USERS_JSON" | jq --argjson i "$1" '
    .[$i] as $u
    | {
        schemas: [
          "urn:ietf:params:scim:schemas:core:2.0:User",
          "urn:ietf:params:scim:schemas:extension:ibm:2.0:User",
          "urn:ietf:params:scim:schemas:extension:ibm:2.0:Notification"
        ],
        userName: $u.username,
        name: { givenName: $u.first_name, familyName: $u.last_name },
        # Verify accepts exactly one email and only type "work".
        emails: [ { type: "work", value: $u.email } ],
        active: true,
        password: $u.password,
        "urn:ietf:params:scim:schemas:extension:ibm:2.0:User": {
          userCategory: "regular",
          # NO emailVerified HERE. This tenant rejects it outright:
          #   CSIAI0111E The supplied JSON contained an invalid attribute: emailVerified
          # It is also unnecessary — nothing in the demo exercises an email
          # round-trip, and the Notification block below (notifyType: NONE) is
          # what actually stops Verify mailing the clear-text password to
          # @corp.com, which does not resolve.
          twoFactorAuthentication: false,
          customAttributes: ($u.attributes | to_entries
                              | map({ name: .key, values: .value }))
        },
        # Suppress the account-created email. Without this Verify mails the
        # clear-text password to an address that does not exist.
        "urn:ietf:params:scim:schemas:extension:ibm:2.0:Notification": {
          notifyType: "NONE"
        }
      }'
}


attr_payload() {
  local name="$1" slot="$2" scim="$3"
  # attributeName is validated with the same letters-only rule as scimName, so
  # both take $scim. Only the human-facing name/description keep the underscore.
  jq -nc --arg name "$name" --arg slot "$slot" --arg scim "$scim" '{
    name: $name,
    description: ("Policy-engine demo claim: " + $name),
    datatype: "string[]",
    scope: "tenant",
    sourceType: "schema",
    schemaAttribute: {
      name: $slot,
      attributeName: $scim,
      scimName: $scim,
      customAttribute: true
    }
  }'
}

create_attrs() {
  echo
  echo "$(dim 'Custom attribute definitions') $(dim "-> ${TENANT_URL}/v1.0/attributes")"
  local entry name slot scim body rest
  for entry in "${ATTRS[@]}"; do
    name="${entry%%:*}"; rest="${entry#*:}"
    slot="${rest%%:*}"; scim="${rest##*:}"
    body="$(attr_payload "$name" "$slot" "$scim")"

    if [ "$DRY_RUN" = true ]; then
      ok "$name" "$(dim "$slot, scimName=$scim (dry-run)")"
      printf '%s\n' "$body" | jq . | sed 's/^/      /'
      continue
    fi

    _split_resp "$(api POST "/v1.0/attributes" "$body")"
    case "$RESP_STATUS" in
      201|200) ok   "$name" "$(dim "defined as $slot (scimName=$scim)")" ;;
      # Verify returns 400 for an already-defined name as well as for genuine
      # validation errors, so the message is the only way to tell them apart.
      # Treat "exists"/"duplicate" as idempotent success and surface the rest.
      400|409)
        if printf '%s' "$RESP_BODY" | grep -qiE 'exist|duplicate|already|in use'; then
          warn "$name" "$(dim 'already defined — skipped')"
        else
          fail "$name" "HTTP $RESP_STATUS"
          printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
            || printf '      %s\n' "$RESP_BODY"
          # CSIAI0096E on [scimName]/[attributeName] is the letters-only rule,
          # not a transient failure: no retry will help, the ATTRS entry needs a
          # letters-only scimName in its third field.
          if printf '%s' "$RESP_BODY" | grep -qE 'CSIAI0096E|not valid for attribute'; then
            echo "$(dim "      scimName '$scim' was rejected. Verify allows LETTERS ONLY here —")"
            echo "$(dim "      no '_' or '-'. Set a letters-only scimName in the third field of")"
            echo "$(dim "      this attribute's ATTRS entry (e.g. gh_permissions -> ghpermissions).")"
          fi
          die "attribute '$name' could not be defined; users would fail validation"
        fi
        ;;
      403) fail "$name" "HTTP 403 — the API client lacks the 'manageAttributes' entitlement"
           die "insufficient entitlements" ;;
      # /v1.0/attributes is plain JSON, not SCIM. A 406 means something sent it
      # scim+json — see the media-type switch in api().
      406) fail "$name" "HTTP 406 — /v1.0/attributes was sent a non-JSON Accept type"
           die "wrong media type for the Attributes API" ;;
      *)   fail "$name" "HTTP $RESP_STATUS"
           printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
             || printf '      %s\n' "$RESP_BODY"
           die "unexpected response defining '$name'" ;;
    esac
  done
}

# ==========================================================================
# 2. Users
# ==========================================================================
# Look up a userName -> id. Used to make create idempotent and to drive --delete.
find_user_id() {
  local username="$1" filter
  # SCIM filter; the space and quotes must be percent-encoded.
  filter="userName%20eq%20%22${username}%22"
  _split_resp "$(api GET "/v2.0/Users?filter=${filter}")"
  [ "$RESP_STATUS" = "200" ] || return 1
  printf '%s' "$RESP_BODY" | jq -r '.Resources[0].id // empty'
}

# Users the tenant flagged "must change password at next sign-in". They are
# created correctly but CANNOT use the password grant until the flag is cleared,
# and nothing in the SCIM API can clear it. See the note in the header.
declare -a NEEDS_PWD_RESET=()

create_users() {
  echo
  echo "$(dim 'Users') $(dim "-> ${TENANT_URL}/v2.0/Users")"
  local i username body existing
  for i in $(seq 0 $((USER_COUNT - 1))); do
    username=$(printf '%s' "$USERS_JSON" | jq -r ".[$i].username")
    body="$(scim_payload "$i")"

    if [ "$DRY_RUN" = true ]; then
      ok "$username" "$(dim '(dry-run)')"
      # Redact the password so the payload can be pasted into an issue.
      printf '%s\n' "$body" | jq '.password = "«redacted»"' | sed 's/^/      /'
      continue
    fi

    # The header is what keeps the new user out of "must change password at next
    # sign-in" — see the pwdReset note in the script header. Nothing in the
    # PAYLOAD can do this.
    _split_resp "$(api POST "/v2.0/Users" "$body" \
                       "usershouldnotneedtoresetpassword: true")"
    case "$RESP_STATUS" in
      201)
        ok "$username" "$(dim "id=$(printf '%s' "$RESP_BODY" | jq -r '.id // "?"')")"
        # The create response already carries pwdReset, so this costs no extra
        # call. true means the tenant requires a password change before the
        # password grant will work — the user exists but cannot mint yet.
        if printf '%s' "$RESP_BODY" | jq -e '
             ."urn:ietf:params:scim:schemas:extension:ibm:2.0:User".pwdReset == true' \
             >/dev/null 2>&1; then
          NEEDS_PWD_RESET+=("$username")
        fi ;;
      409)
        # Already present. Overwriting a user's attributes is a bigger action
        # than "import" implies, so report it and let the operator choose
        # --delete then re-run.
        existing=$(find_user_id "$username" || true)
        warn "$username" "$(dim "exists${existing:+ (id=$existing)} — left unchanged; use --delete to replace")" ;;
      400)
        fail "$username" "HTTP 400"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        echo "$(dim '      A 400 here is usually an undefined custom attribute:')"
        echo "$(dim '      run with --attrs-only first, or check the slot mapping.')"
        die "user '$username' rejected" ;;
      403)
        fail "$username" "HTTP 403 — the API client lacks the 'manageUsers' entitlement"
        die "insufficient entitlements" ;;
      *)
        fail "$username" "HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        die "unexpected response creating '$username'" ;;
    esac
  done
}

# ==========================================================================
# 3. Manager links
# ==========================================================================
# A SECOND PASS, run after every user exists, because the manager reference holds
# the manager's SCIM **id** and that id does not exist until they are created.
# bob names alice; whether alice happens to be created first is an accident of
# CSV row order, so this does not depend on it.
#
# Written with PATCH op=replace rather than in the create payload: replace is
# idempotent (it sets the same id on a re-run) and it works on users that already
# existed, which is the common case when re-running against a live tenant where
# create returns 409 and changes nothing.
#
# The claim this feeds is produced on the CLIENT by the introspection mapper
#   statements:
#     - context: manager := user.getManager()
#     - return: context.manager.userName
# so what lands here is the relationship; the userName in the token is derived
# from it by that mapper. A user with no manager gets no link and no claim.
declare -a MANAGER_UNLINKED=()

link_managers() {
  # Nothing to do if no row names a manager — do not print an empty section.
  local pairs
  pairs=$(printf '%s' "$USERS_JSON" | jq -r '.[] | select(.manager != "")
    | "\(.username)\t\(.manager)"')
  [ -n "$pairs" ] || return 0

  echo
  echo "$(dim 'Manager links') $(dim "-> PATCH ${TENANT_URL}/v2.0/Users/<id>")"

  local username mgr uid mgr_id body
  while IFS=$'\t' read -r username mgr; do
    [ -n "$username" ] || continue

    if [ "$DRY_RUN" = true ]; then
      ok "$username" "$(dim "would set manager -> $mgr (dry-run; ids resolved on a real run)")"
      continue
    fi

    # Both sides resolve by userName. The manager need not be in the CSV, but it
    # must exist on the tenant — the CSV-internal case is already checked at parse
    # time, so a failure here means the tenant is missing them.
    if ! uid=$(find_user_id "$username") || [ -z "$uid" ]; then
      warn "$username" "$(dim 'not on the tenant — no manager link')"
      MANAGER_UNLINKED+=("$username -> $mgr")
      continue
    fi
    if ! mgr_id=$(find_user_id "$mgr") || [ -z "$mgr_id" ]; then
      fail "$username" "$(dim "manager '$mgr' not found on the tenant")"
      MANAGER_UNLINKED+=("$username -> $mgr")
      continue
    fi

    # $ref is generated by the tenant; only `value` is writable.
    body=$(jq -nc --arg s "$ENTERPRISE_SCHEMA" --arg id "$mgr_id" '{
      schemas: ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
      Operations: [ { op: "replace", path: ($s + ":manager"),
                      value: { value: $id } } ]
    }')

    _split_resp "$(api PATCH "/v2.0/Users/$uid" "$body")"
    case "$RESP_STATUS" in
      200|204) ok "$username" "$(dim "manager -> $mgr ($mgr_id)")" ;;
      400)
        fail "$username" "HTTP 400 — the manager reference was rejected"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        echo "$(dim "      Expected path: ${ENTERPRISE_SCHEMA}:manager")"
        echo "$(dim '      A tenant without the enterprise SCIM extension enabled would')"
        echo "$(dim '      reject this; the manager claim then has no source.')"
        MANAGER_UNLINKED+=("$username -> $mgr") ;;
      403)
        fail "$username" "HTTP 403 — the API client lacks the 'manageUsers' entitlement"
        MANAGER_UNLINKED+=("$username -> $mgr") ;;
      *)
        fail "$username" "HTTP $RESP_STATUS"
        printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
          || printf '      %s\n' "$RESP_BODY"
        MANAGER_UNLINKED+=("$username -> $mgr") ;;
    esac
  done <<< "$pairs"
}

delete_users() {
  echo
  echo "$(yellow 'Deleting') $(dim "the ${USER_COUNT} users in $(basename "$CSV") from ${TENANT_URL}")"
  local i username id
  for i in $(seq 0 $((USER_COUNT - 1))); do
    username=$(printf '%s' "$USERS_JSON" | jq -r ".[$i].username")

    if [ "$DRY_RUN" = true ]; then
      ok "$username" "$(dim '(dry-run) would DELETE /v2.0/Users/<id>')"
      continue
    fi

    if ! id=$(find_user_id "$username") || [ -z "$id" ]; then
      warn "$username" "$(dim 'not present — nothing to delete')"
      continue
    fi
    _split_resp "$(api DELETE "/v2.0/Users/$id")"
    case "$RESP_STATUS" in
      200|204) ok   "$username" "$(dim "deleted (id=$id)")" ;;
      404)     warn "$username" "$(dim 'already gone')" ;;
      *)       fail "$username" "HTTP $RESP_STATUS"
               printf '%s\n' "$RESP_BODY" | jq . 2>/dev/null | sed 's/^/      /' \
                 || printf '      %s\n' "$RESP_BODY" ;;
    esac
  done
  # Attribute definitions are left in place on purpose: they are tenant schema,
  # they hold no user data, and re-running the import needs them.
  echo
  echo "$(dim 'Attribute definitions were left in place (tenant schema, no user data).')"
}

# ==========================================================================
# main
# ==========================================================================
echo
echo "$(dim 'tenant  ')" "$TENANT_URL"
echo "$(dim 'source  ')" "$CSV ($USER_COUNT users)"
[ "$DRY_RUN" = true ] && echo "$(dim 'mode    ')" "$(yellow 'dry-run — no requests will be sent')"

[ "$DRY_RUN" = false ] && get_token

if [ "$DO_DELETE" = true ]; then
  delete_users
else
  [ "$DO_ATTRS" = true ] && create_attrs
  if [ "$DO_USERS" = true ]; then
    create_users
    # Second pass: needs every user to exist, including ones create_users
    # skipped as already-present (409).
    link_managers
  fi
fi

echo
if [ "$DRY_RUN" = true ]; then
  echo "$(dim 'Dry run only — nothing was sent to the tenant.')"
else
  # Surfaced BEFORE the "verify it end to end" hint, because on a tenant with
  # this policy those commands cannot succeed yet and the reason is not
  # discoverable from their error (CSIAQ0267E names no user and no cause).
  if [ "${#NEEDS_PWD_RESET[@]}" -gt 0 ]; then
    echo "$(yellow 'MUST CHANGE PASSWORD') $(dim '— these users cannot use the password grant yet:')"
    for u in "${NEEDS_PWD_RESET[@]}"; do echo "  $(dim "• $u")"; done
    echo
    echo "$(dim '  These came back pwdReset=true ("must change password at next sign-in"),')"
    echo "$(dim '  so the password grant will refuse them:')"
    echo "$(dim '    CSIAQ0267E The password must be changed.')"
    echo
    echo "$(dim '  This script sends the header that prevents it:')"
    echo "$(dim '    usershouldnotneedtoresetpassword: true')"
    echo "$(dim '  so seeing this means the tenant did not honour it. Nothing in the SCIM')"
    echo "$(dim '  PAYLOAD can substitute — see the pwdReset note in the script header.')"
    echo
    echo "$(dim '  Clear it per user in the console (Directory -> Users and groups -> <user>')"
    echo "$(dim '  -> remove the password-change requirement), and please note the tenant')"
    echo "$(dim '  version: the header working is what makes this script unattended.')"
    echo
  fi
  if [ "${#MANAGER_UNLINKED[@]}" -gt 0 ]; then
    echo "$(yellow 'NO MANAGER LINK') $(dim '— these users carry no manager claim:')"
    for u in "${MANAGER_UNLINKED[@]}"; do echo "  $(dim "• $u")"; done
    echo
    echo "$(dim '  The client mapper returns getManager().userName, so without the link the')"
    echo "$(dim '  claim is absent and require_approval(from: claim.manager) has nothing to')"
    echo "$(dim '  resolve — scenario 11 cannot route its CIBA approval.')"
    echo
  fi
  echo "$(green 'Done.') Verify the result end to end with:"
  echo "  $(dim './mint-verify-token.sh alice | cut -d. -f2 | base64 -d 2>/dev/null | jq .')"
  echo "  $(dim './verify-ibm-verify-token-exchange.sh')"
  echo
  echo "$(dim 'Custom attributes reach the token only once the tenant'"'"'s clients map them')"
  echo "$(dim 'as claims. That mapping is client config, not user data, and this script')"
  echo "$(dim 'does not touch it — check roles/permissions/teams/gh_permissions appear in')"
  echo "$(dim 'the decoded token above before running the walkthrough.')"
  echo
  echo "$(dim 'The manager claim is bob'"'"'s, not alice'"'"'s, and comes from the relationship')"
  echo "$(dim 'set above rather than a custom attribute — check it separately:')"
  echo "  $(dim './mint-verify-token.sh bob | cut -d. -f2 | base64 -d 2>/dev/null | jq .manager')"
  echo "$(dim 'Expect the STRING "alice". A missing claim means the client has no manager')"
  echo "$(dim 'mapper (getManager().userName); [] or ["alice"] means it was mapped like one')"
  echo "$(dim 'of the set claims, which the CIBA login_hint cannot use.')"
fi
