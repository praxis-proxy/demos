#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Register the demo's workloads with SPIRE. A registration entry says which
# processes get which SPIFFE ID: here, a process running as uid 1001 in the
# `workloads` container, on the node that joined as spiffe://policy.demo/node/
# demo-host, is the hr-copilot agent. Any other uid gets no SVID.
#
# The SPIFFE ID follows the usual deployment-shaped convention (namespace and
# service account), so it names where the agent runs, not which agent it is.
# Keycloak's hr-copilot-agent client is bound to it
# (spire/configure-federated-client.sh).
#
# Idempotent: an existing entry for the same SPIFFE ID is replaced.
#
# Prereq: WITH_SPIRE=1 ./restart.sh, which runs this.
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.spire.yml)
SERVER=("${COMPOSE[@]}" exec -T spire-server /opt/spire/bin/spire-server)

PARENT_ID="${PARENT_ID:-spiffe://policy.demo/node/demo-host}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://policy.demo/ns/hr/sa/copilot}"
SELECTOR="${SELECTOR:-unix:uid:1001}"

for id in $("${SERVER[@]}" entry show -spiffeID "$SPIFFE_ID" | awk '/^Entry ID/ {print $4}'); do
  "${SERVER[@]}" entry delete -entryID "$id" >/dev/null
done
"${SERVER[@]}" entry create -parentID "$PARENT_ID" -spiffeID "$SPIFFE_ID" -selector "$SELECTOR" >/dev/null
echo "-> registered $SPIFFE_ID for $SELECTOR"
