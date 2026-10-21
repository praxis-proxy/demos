#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Run the scenarios and report pass/fail.
#
# Each scenario asserts its own expectations and exits non-zero when one is
# not met (see scenarios/_lib.sh), so this only has to run them and total it
# up. Exits non-zero if anything failed, which is what makes it usable as a
# check before bumping a pin or cutting a release.
#
# Usage, from this directory:
#   ./run-scenarios.sh                 the running gateway, whatever config
#   ./run-scenarios.sh --all-configs   cedar, then cel, then opa, restarting
#                                      the gateway for each
#   ./run-scenarios.sh 03 07           just these
#
# USE_VERIFY=true switches the IdP from Keycloak to IBM Verify. It selects both
# halves of the path, which have to agree: which IdP the scenarios mint from
# (scenarios/_lib.sh) and which configs --all-configs restarts the gateway on.
#
#   USE_VERIFY=true ./run-scenarios.sh --all-configs
#     → praxis-verify-cedar.yaml, praxis-verify-cel.yaml, praxis-verify-opa.yaml
#
# Needs .env.verify with VERIFY_GATEWAY_CLIENT_SECRET; see .env.verify.example.
#
# Scenario 11 needs the CIBA approval loop; it is driven unattended here. On the
# Verify path it is expected to fail: the CIBA plugin still points at Keycloak
# and the tenant blocks the grant. Run it on the Keycloak path instead.
#
# Two scenarios are bound to one IdP by capability rather than config, in
# opposite directions, and each skips (exit 77) on the other path:
#
#   13  Keycloak only — SPIFFE workload identity. Needs WITH_SPIRE=1.
#   14  Verify only   — Agent Registry governance. Needs USE_VERIFY=true and
#                       ./verify/import-verify-clients.sh to have run.
#
# See docs/idp-usage-by-scenario.md for why neither ports.
set -uo pipefail

cd "$(dirname "$0")"

GATEWAY_BIN="${GATEWAY_BIN:-$PWD/gateway/target/release/policy-engine-gateway}"

# Each PDP config expresses the same deny differently, and scenario 05 asserts
# whichever is running. The IdP half of the config name is irrelevant here —
# only the PDP decides the violation string — so the Keycloak and Verify
# variants of one PDP share a line. Keep this beside the config list it describes.
pdp_violation_for() {
  case "$1" in
    praxis-cel.yaml|praxis-verify-cel.yaml) echo "cel.policy_denied" ;;
    praxis-opa.yaml|praxis-verify-opa.yaml) echo "opa.policy_denied" ;;
    # praxis.yaml and praxis-verify-cedar.yaml, plus anything unrecognised:
    # Cedar is the default PDP, and default-deny is the safe thing to assert.
    *)                                      echo "cedar.default_deny" ;;
  esac
}

# USE_VERIFY picks the IdP; it is read by scenarios/_lib.sh to decide which IdP
# to MINT from, and the gateway has to be on a matching config or every scenario
# fails at identity.resolve with auth.untrusted_issuer. So the same switch
# selects the config set here: the PDP axis is what --all-configs sweeps, and the
# IdP axis is held fixed by USE_VERIFY.
#
# Both axes are listed Cedar, CEL, OPA so the two sweeps are directly comparable.
if [ "${USE_VERIFY:-}" = "true" ]; then
  CONFIGS=(praxis-verify-cedar.yaml praxis-verify-cel.yaml praxis-verify-opa.yaml)
  DEFAULT_CONFIG="praxis-verify-cedar.yaml"
else
  CONFIGS=(praxis.yaml praxis-cel.yaml praxis-opa.yaml)
  DEFAULT_CONFIG="praxis.yaml"
fi

ALL_CONFIGS=0
WANTED=()
for arg in "$@"; do
  case "$arg" in
    --all-configs) ALL_CONFIGS=1 ;;
    # Print the whole header block rather than a fixed line range, so editing
    # the comment above cannot silently truncate --help mid-sentence.
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d'; exit 0 ;;
    *) WANTED+=("$arg") ;;
  esac
done

scenarios_to_run() {
  if [ "${#WANTED[@]}" -eq 0 ]; then
    ls scenarios/[0-9]*.sh | sort
  else
    local n
    for n in "${WANTED[@]}"; do ls scenarios/"$n"-*.sh 2>/dev/null; done
  fi
}

run_one_config() {
  local config="$1" failed=0 passed=0 skipped=0 names=() rc
  export PDP_DENY_VIOLATION="$(pdp_violation_for "$config")"

  printf '\n\033[1;34m══ %s (deny violation: %s) ══\033[0m\n' "$config" "$PDP_DENY_VIOLATION"

  local f name
  for f in $(scenarios_to_run); do
    name="$(basename "$f" .sh)"
    # 11 blocks on a human click unless told otherwise.
    rc=0
    AUTO_APPROVE=1 bash "$f" >"/tmp/scenario-$name.log" 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '  \033[1;32m✓\033[0m %s\n' "$name"
      passed=$((passed + 1))
    elif [ "$rc" -eq 77 ]; then
      # A scenario that needs an optional layer (13 needs the SPIRE overlay)
      # exits 77 when that layer is not running.
      printf '  \033[1;33m-\033[0m %s (skipped: optional layer not running)\n' "$name"
      skipped=$((skipped + 1))
    else
      printf '  \033[1;31m✗\033[0m %s\n' "$name"
      # Only the failed expectations, so a failure is readable without
      # opening the log.
      grep -E '✗|expectation\(s\) failed' "/tmp/scenario-$name.log" | sed 's/^/      /'
      printf '      full output: /tmp/scenario-%s.log\n' "$name"
      failed=$((failed + 1))
      names+=("$name")
    fi
  done

  printf '\n  %s passed, %s failed' "$passed" "$failed"
  [ "$skipped" -ne 0 ] && printf ', %s skipped' "$skipped"
  [ "$failed" -ne 0 ] && printf ' (%s)' "${names[*]}"
  printf '\n'
  return "$failed"
}

TOTAL_FAILED=0

if [ "$ALL_CONFIGS" -eq 1 ]; then
  for config in "${CONFIGS[@]}"; do
    printf '\n\033[1;34m[run-scenarios]\033[0m restarting the stack on %s\n' "$config"
    if ! GATEWAY_CONFIG="$config" GATEWAY_BIN="$GATEWAY_BIN" ./restart.sh >"/tmp/restart-$config.log" 2>&1; then
      printf '  \033[1;31m✗\033[0m restart failed for %s (see /tmp/restart-%s.log)\n' "$config" "$config"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      continue
    fi
    run_one_config "$config" || TOTAL_FAILED=$((TOTAL_FAILED + $?))
  done
else
  run_one_config "${GATEWAY_CONFIG:-$DEFAULT_CONFIG}" || TOTAL_FAILED=$?
fi

printf '\n'
if [ "$TOTAL_FAILED" -ne 0 ]; then
  printf '\033[1;31m%s scenario(s) failed\033[0m\n' "$TOTAL_FAILED"
  exit 1
fi
printf '\033[1;32mall scenarios passed\033[0m\n'
