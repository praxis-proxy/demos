#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Fetch a JWT-SVID the way a workload does: from the SPIFFE Workload API, as a
# process running under the given uid in the `workloads` container. SPIRE
# attests the calling process and issues the SVID of the registration entry it
# matches, or none at all.
#
#   ./spire/fetch-svid.sh UID AUDIENCE     prints the JWT-SVID, or exits 1
#
# A new registration entry takes a few seconds to reach the agent, so a
# refusal is retried for up to SVID_WAIT seconds (default 20; 0 to try once).
set -euo pipefail

uid="$1" audience="$2"
wait_s="${SVID_WAIT:-20}"
cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.spire.yml --profile attestation)

errors=$(mktemp)
trap 'rm -f "$errors"' EXIT

deadline=$(( $(date +%s) + wait_s ))
while :; do
  # Parse stdout only. A compose wrapper can write to stderr, and `podman
  # compose` does: a banner wrapped in terminal colour codes, whose reset code
  # lands at the start of the next line. Merged into stdout, that line no
  # longer starts with "token(" and a fetch that succeeded reads as a failure.
  out=$("${COMPOSE[@]}" exec -T -u "$uid" workloads spire-agent api fetch jwt \
          -audience "$audience" -socketPath /opt/spire/sockets/agent.sock 2>"$errors") || true
  # Output is "token(<spiffe id>):" followed by the JWT on the next line.
  svid=$(printf '%s\n' "$out" | awk '/^token\(/ {getline; gsub(/[[:space:]]/, ""); print; exit}')
  if [ -n "$svid" ]; then
    printf '%s\n' "$svid"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    # The agent's own error, without the wrapper's banner, its "Error: executing"
    # line, or colour codes.
    reason=$(sed $'s/\033\\[[0-9;]*m//g' "$errors" \
               | grep -v -e 'external compose provider' -e '^Error: executing ' \
               | grep -v '^[[:space:]]*$' | tail -1)
    printf '%s\n' "${reason:-$(printf '%s\n' "$out" | tail -1)}" >&2
    exit 1
  fi
  sleep 2
done