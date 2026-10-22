#!/usr/bin/env bash
#
# Render IBM Verify policies with tenant and client ids from the environment
# or post_deploy_variables.json. restart.sh calls this for the selected variant.
#
# Usage:
#   ./render-verify-config.sh [opa|cel|cedar ...]
#   ./render-verify-config.sh --force       # overwrite current output
#   ./render-verify-config.sh --check       # fail if output is stale
#   ./render-verify-config.sh --print cel   # stdout; one variant only
#
# Substitutes VERIFY_TENANT_URL, VERIFY_GATEWAY_CLIENT_ID, VERIFY_AGENT_ID, and
# VERIFY_AGENT_READER_CLIENT_ID. Optional agent ids may be empty. Secrets remain
# runtime environment lookups. Unknown ${UPPER_SNAKE} placeholders fail; Praxis
# expressions such as ${args.repo_name} pass through unchanged.
# Requires: python3.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PDV="post_deploy_variables.json"

# Supported template/output pairs.
ALL_VARIANTS=(opa cel cedar)

tmpl_for() { echo "policy-verify-$1.yaml.tmpl"; }
out_for()  { echo "policy-verify-$1.yaml"; }

is_variant() {
  local v
  for v in "${ALL_VARIANTS[@]}"; do [ "$1" = "$v" ] && return 0; done
  return 1
}

FORCE=false
CHECK=false
PRINT=false
VARIANTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=true ;;
    --check) CHECK=true ;;
    --print) PRINT=true ;;
    -h|--help) sed -n '2,/^# Requires:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      if is_variant "$1"; then
        VARIANTS+=("$1")
      else
        echo "unknown variant: $1 (expected one of: ${ALL_VARIANTS[*]})" >&2
        exit 2
      fi
      ;;
  esac
  shift
done

# No variant named means all of them, so a bare run and `--check` stay
# whole-world operations.
if [ "${#VARIANTS[@]}" -eq 0 ]; then
  VARIANTS=("${ALL_VARIANTS[@]}")
fi

red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
dim()   { printf '\033[2m%s\033[0m' "$*"; }
die()   { echo "$(red 'fatal:') $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is required but not on PATH"

for _v in "${VARIANTS[@]}"; do
  _t="$(tmpl_for "$_v")"
  [ -f "$_t" ] || die "template not found: $_t"
done

# Three policy documents on one stdout is not a valid config for anything, so
# --print insists on a single variant rather than silently producing garbage.
if [ "$PRINT" = true ] && [ "${#VARIANTS[@]}" -ne 1 ]; then
  die "--print needs exactly one variant (one of: ${ALL_VARIANTS[*]})"
fi

# Exported values override post_deploy_variables.json.
TENANT_URL="${VERIFY_TENANT_URL:-}"
CLIENT_ID="${VERIFY_GATEWAY_CLIENT_ID:-}"
# Agent ids are optional for tenants without Agent Registry. Scenario 14 skips
# when they are absent; its route cannot authorize an unconfigured agent.
AGENT_ID="${VERIFY_AGENT_ID:-}"
# The gateway's runtime credential for reading agent status: a readAgents-only
# API client, NOT the admin pair. See the note in the Verify templates.
READER_CLIENT_ID="${VERIFY_AGENT_READER_CLIENT_ID:-}"

if [ -z "$TENANT_URL" ] || [ -z "$CLIENT_ID" ]; then
  [ -f "$PDV" ] || die "$PDV not found, and VERIFY_TENANT_URL / VERIFY_GATEWAY_CLIENT_ID are not both set"
  command -v jq >/dev/null 2>&1 || die "jq is required to read defaults from $PDV (or export both variables)"

  if [ -z "$TENANT_URL" ]; then
    _ep=$(jq -r '.variables.IBM_VERIFY_TOKEN_ENDPOINT // empty' "$PDV")
    [ -n "$_ep" ] || die "IBM_VERIFY_TOKEN_ENDPOINT missing from $PDV; export VERIFY_TENANT_URL instead"
    TENANT_URL="${_ep%/oauth2/token}"
    [ "$TENANT_URL" != "$_ep" ] \
      || die "could not derive a tenant URL from '$_ep' (expected it to end in /oauth2/token)"
  fi
  if [ -z "$CLIENT_ID" ]; then
    CLIENT_ID=$(jq -r '.variables.GATEWAY_CLIENT_ID // empty' "$PDV")
    [ -n "$CLIENT_ID" ] || die "GATEWAY_CLIENT_ID missing from $PDV; export VERIFY_GATEWAY_CLIENT_ID instead"
  fi
fi

# Both agent values are best-effort: absent is a valid state (no Agent Identity
# on this tenant), so they warn rather than die.
if [ -z "$AGENT_ID" ] && [ -f "$PDV" ] && command -v jq >/dev/null 2>&1; then
  AGENT_ID=$(jq -r '.variables.VERIFY_AGENT_ID // empty' "$PDV")
fi
if [ -z "$READER_CLIENT_ID" ]; then
  # Lives in .env.verify, not the PDV file: it is paired with a secret, and
  # that is where this demo keeps live tenant credentials.
  [ -f ./.env.verify ] && READER_CLIENT_ID=$(
    # shellcheck disable=SC1091
    . ./.env.verify >/dev/null 2>&1 || true
    printf '%s' "${VERIFY_AGENT_READER_CLIENT_ID:-}"
  )
fi

# Normalize the tenant URL before constructing issuer URLs.
TENANT_URL="${TENANT_URL%/}"

case "$TENANT_URL" in
  https://*) ;;
  http://*) die "VERIFY_TENANT_URL is http://; Verify is HTTPS and the config sets no insecure_http" ;;
  *) die "VERIFY_TENANT_URL must be an absolute https:// URL, got '$TENANT_URL'" ;;
esac

# Substitute renderer placeholders and preserve Praxis expressions.
render() {
  python3 -I - "$1" "$TENANT_URL" "$CLIENT_ID" "$AGENT_ID" "$READER_CLIENT_ID" <<'PY'
import re, sys

tmpl_path, tenant_url, client_id = sys.argv[1], sys.argv[2], sys.argv[3]
agent_id, reader_client_id = sys.argv[4], sys.argv[5]
with open(tmpl_path) as fh:
    text = fh.read()

mapping = {
    "VERIFY_TENANT_URL": tenant_url,
    "VERIFY_GATEWAY_CLIENT_ID": client_id,
    # Scenario 14. Empty is allowed: see the note where these are resolved.
    "VERIFY_AGENT_ID": agent_id,
    "VERIFY_AGENT_READER_CLIENT_ID": reader_client_id,
}

# Match renderer placeholders only; preserve Praxis expressions like ${args.repo_name}.
OURS = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")

# Reject unknown renderer placeholders.
unknown = {m.group(1) for m in OURS.finditer(text) if m.group(1) not in mapping}
if unknown:
    sys.exit("template references unknown variable(s): "
             + ", ".join(sorted(unknown))
             + "\nAdd them to render-verify-config.sh or fix the template.")

for name, value in mapping.items():
    text = text.replace("${" + name + "}", value)

leftover = sorted({m.group(0) for m in OURS.finditer(text)})
if leftover:
    sys.exit("unsubstituted placeholder(s) remain: " + ", ".join(leftover))

# Prefix generated output with its source and tenant identifiers.
banner = (
    "# GENERATED FILE — DO NOT EDIT.\n"
    "#\n"
    f"# Rendered from {tmpl_path} by render-verify-config.sh.\n"
    "# Edit the .tmpl and re-run; this file is gitignored and is overwritten on\n"
    "# every Verify run of restart.sh.\n"
    "#\n"
    f"#   tenant     {tenant_url}\n"
    f"#   client_id  {client_id}\n"
    "#\n"
)
sys.stdout.write(banner + text)
PY
}

if [ "$PRINT" = true ]; then
  # Arity already checked above, so there is exactly one.
  render "$(tmpl_for "${VARIANTS[0]}")"
  exit 0
fi

# Continue after a failed variant and report all stale or broken outputs.
STALE=0

for variant in "${VARIANTS[@]}"; do
  tmpl="$(tmpl_for "$variant")"
  out="$(out_for "$variant")"

  if ! NEW="$(render "$tmpl")"; then
    STALE=1
    continue
  fi

  if [ -f "$out" ] && [ "$NEW" = "$(cat "$out")" ]; then
    if [ "$CHECK" = true ]; then
      echo "  $(green ✓) $out is up to date"
      continue
    fi
    if [ "$FORCE" = false ]; then
      echo "  $(green ✓) $out $(dim 'already up to date')"
      continue
    fi
  elif [ "$CHECK" = true ]; then
    echo "  $(red ✗) $out is missing or stale — run ./render-verify-config.sh $variant" >&2
    STALE=1
    continue
  fi

  # Warn before clobbering a hand-edited file that predates the template, so the
  # edits can be moved into the .tmpl rather than silently lost.
  if [ -f "$out" ] && ! head -1 "$out" | grep -q 'GENERATED FILE'; then
    echo "  $(red '!') $out exists and was NOT generated by this script." >&2
    echo "      Overwriting it. If it has hand edits, move them into $tmpl." >&2
  fi

  printf '%s\n' "$NEW" > "$out"
  echo "  $(green ✓) rendered $out $(dim "(tenant ${TENANT_URL}, client ${CLIENT_ID:0:8}…)")"
done

exit "$STALE"
