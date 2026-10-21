#!/usr/bin/env bash
# Render policy-verify-<variant>.yaml from policy-verify-<variant>.yaml.tmpl,
# for each of the three PDP variants on the IBM Verify path (opa, cel, cedar).
#
# The Verify path's tenant URL and exchange client_id are tenant-specific, and
# Verify GENERATES client ids — so a rebuilt tenant invalidates whatever is
# committed. Praxis has no env-var support for `client_id` (only the client
# SECRET has a `client_secret_source: {kind: env_var}` indirection; client_id is
# a plain String read straight into the outbound Basic auth header), so
# substitution has to happen before the gateway reads the file. This script is
# that step.
#
# The two substituted values are variant-independent, so they are resolved once
# and every selected variant gets the same tenant and client id.
#
# Usage:
#   ./render-verify-config.sh              # render all three, skipping up-to-date
#   ./render-verify-config.sh cel          # render only the CEL variant
#   ./render-verify-config.sh opa cedar    # render a subset
#   ./render-verify-config.sh --force      # re-render even if up to date
#   ./render-verify-config.sh --check      # verify only; non-zero if any stale
#   ./render-verify-config.sh --print cel  # render to stdout, write nothing
#
# --print needs exactly one variant: concatenating three policy documents onto
# one stream produces a file that is not a valid config for anything.
#
# restart.sh calls this automatically for any *verify* GATEWAY_CONFIG, passing
# the variant that matches it, so the normal path needs nothing.
#
# Requires: python3 (already required by verify/import-verify-*.sh).
# Deliberately NOT envsubst: that is gettext, absent from a stock macOS and from
# minimal Linux images, and it would substitute every $VAR in the file rather
# than the two intended ones.
#
# ---------------------------------------------------------------------------
# What is and is not substituted
# ---------------------------------------------------------------------------
#   ${VERIFY_TENANT_URL}         default: IBM_VERIFY_TOKEN_ENDPOINT in
#                                post_deploy_variables.json, minus /oauth2/token
#   ${VERIFY_GATEWAY_CLIENT_ID}  default: GATEWAY_CLIENT_ID in that same file
#
# The client SECRET is deliberately absent. It stays a runtime lookup by the
# gateway (client_secret_source: {kind: env_var}), so a live credential never
# lands in a rendered file. Keep it that way: this output is a plain file in the
# working tree, and the gitignore entry is the only thing between it and a commit.
#
# The Keycloak CIBA endpoints in the template are literal localhost URLs and are
# NOT templated — that plugin still points at Keycloak (see the note in the
# template), so templating them would imply a portability that does not exist.
#
# ---------------------------------------------------------------------------
# Two kinds of ${...}, and why the distinction is load-bearing
# ---------------------------------------------------------------------------
# The Cedar template writes `id: ${args.repo_name}` — a PRAXIS interpolation,
# resolved per-request by the gateway from the live tool args. It must survive
# into the rendered file untouched.
#
# So the two namespaces are split by case, which is why the convention is worth
# keeping:
#
#   ${UPPER_SNAKE}   this script's placeholders. Unknown ones abort the render,
#                    and any left unsubstituted abort it too.
#   ${anything.else} Praxis's own, passed through verbatim.
#
# The strictness on the first is the point: an unresolved ${VERIFY_...} would
# reach the gateway as a literal string, pass the non-empty client_id check, and
# fail much later at the token endpoint as invalid_client — a long way from the
# typo that caused it.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PDV="post_deploy_variables.json"

# The variants, in the order they are rendered and reported. A variant is just a
# (template, output) pair sharing one tenant and client id, so adding a fourth
# PDP means one entry here and one template file — nothing else in this script.
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

# --- resolve the values ----------------------------------------------------
# An already-exported value wins, so a one-off run or CI can override without
# editing any file. Otherwise fall back to post_deploy_variables.json, which is
# what verify/import-verify-clients.sh writes the generated ids into.
TENANT_URL="${VERIFY_TENANT_URL:-}"
CLIENT_ID="${VERIFY_GATEWAY_CLIENT_ID:-}"
# Scenario 14's agent principal. Optional: the Verify templates reference these
# only in the agent route, and a tenant without Agent Identity (Early Access)
# has neither. Empty renders a config whose agent route cannot authorize, which
# is what makes scenario 14 skip rather than fail — see its exit-77 guard.
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

# A trailing slash would produce a double slash in the issuer, and an issuer
# mismatch fails as auth.untrusted_issuer — legible, but not obviously a config
# typo. Normalise instead.
TENANT_URL="${TENANT_URL%/}"

case "$TENANT_URL" in
  https://*) ;;
  http://*) die "VERIFY_TENANT_URL is http://; Verify is HTTPS and the config sets no insecure_http" ;;
  *) die "VERIFY_TENANT_URL must be an absolute https:// URL, got '$TENANT_URL'" ;;
esac

# --- render ---------------------------------------------------------------
# Substitute exactly the two known placeholders, then assert no ${UPPER_SNAKE}
# remains. A leftover one would otherwise reach the gateway as a literal string:
# an unresolved client_id passes the non-empty check and fails much later at the
# token endpoint as invalid_client.
#
# Praxis's own ${args.*} interpolations are lower-case and dotted, and are
# deliberately left alone — see the namespace note in the header.
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

# This script owns the ${UPPER_SNAKE} namespace; Praxis owns everything else
# (e.g. ${args.repo_name} in the Cedar template, resolved per-request by the
# gateway). Matching only UPPER_SNAKE keeps the two from colliding.
OURS = re.compile(r"\$\{([A-Z][A-Z0-9_]*)\}")

# Within our own namespace, an unrecognised name is a typo or a new variable
# someone forgot to wire up, and must not pass silently.
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

# The generated file must not be edited by hand, and it is gitignored — say both
# at the top, since that is the only place a reader will look.
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

# One variant per iteration. A failure in one is recorded and the rest still
# run: on a --check that means the report names every stale file rather than
# only the first, and on a render it means one broken template does not hide
# the state of the others.
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
