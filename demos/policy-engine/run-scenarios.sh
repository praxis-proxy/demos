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
# Scenario 11 needs the CIBA approval loop; it is driven unattended here.
set -uo pipefail

cd "$(dirname "$0")"

GATEWAY_BIN="${GATEWAY_BIN:-$PWD/gateway/target/release/policy-engine-gateway}"

# Each PDP config expresses the same deny differently, and scenario 05 asserts
# whichever is running. Keep this beside the config list it describes.
pdp_violation_for() {
  case "$1" in
    praxis-cel.yaml) echo "cel.policy_denied" ;;
    praxis-opa.yaml) echo "opa.policy_denied" ;;
    *)               echo "cedar.default_deny" ;;
  esac
}

ALL_CONFIGS=0
WANTED=()
for arg in "$@"; do
  case "$arg" in
    --all-configs) ALL_CONFIGS=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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
  local config="$1" failed=0 passed=0 names=()
  export PDP_DENY_VIOLATION="$(pdp_violation_for "$config")"

  printf '\n\033[1;34m══ %s (deny violation: %s) ══\033[0m\n' "$config" "$PDP_DENY_VIOLATION"

  local f name
  for f in $(scenarios_to_run); do
    name="$(basename "$f" .sh)"
    # 11 blocks on a human click unless told otherwise.
    if AUTO_APPROVE=1 bash "$f" >"/tmp/scenario-$name.log" 2>&1; then
      printf '  \033[1;32m✓\033[0m %s\n' "$name"
      passed=$((passed + 1))
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
  [ "$failed" -ne 0 ] && printf ' (%s)' "${names[*]}"
  printf '\n'
  return "$failed"
}

TOTAL_FAILED=0

if [ "$ALL_CONFIGS" -eq 1 ]; then
  for config in praxis.yaml praxis-cel.yaml praxis-opa.yaml; do
    printf '\n\033[1;34m[run-scenarios]\033[0m restarting the stack on %s\n' "$config"
    if ! GATEWAY_CONFIG="$config" GATEWAY_BIN="$GATEWAY_BIN" ./restart.sh >"/tmp/restart-$config.log" 2>&1; then
      printf '  \033[1;31m✗\033[0m restart failed for %s (see /tmp/restart-%s.log)\n' "$config" "$config"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
      continue
    fi
    run_one_config "$config" || TOTAL_FAILED=$((TOTAL_FAILED + $?))
  done
else
  run_one_config "${GATEWAY_CONFIG:-praxis.yaml}" || TOTAL_FAILED=$?
fi

printf '\n'
if [ "$TOTAL_FAILED" -ne 0 ]; then
  printf '\033[1;31m%s scenario(s) failed\033[0m\n' "$TOTAL_FAILED"
  exit 1
fi
printf '\033[1;32mall scenarios passed\033[0m\n'
