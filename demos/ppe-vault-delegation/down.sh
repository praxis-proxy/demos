#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

if [ -s .state/gateway.pid ]; then
  pid="$(<.state/gateway.pid)"
  kill "$pid" 2>/dev/null || true
fi
docker compose down -v --remove-orphans
rm -rf "$DEMO_DIR/.state"
echo "demo stopped; ephemeral Vault data, keys, JWTs, and logs removed"
