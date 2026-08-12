#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Build the demo gateway and echo the binary path on stdout.
#
# The gateway (./gateway) is a thin binary that composes praxis-ai's AI
# filters (mcp classifier, ...) with the CPEX/HIL `policy` filter: it depends
# on praxis-ai's server and enables `cpex-policy-engine` on praxis-proxy-filter
# (pinned to the same git tag as `ai`'s own dependency so Cargo resolves one
# shared, feature-unified instance — see gateway/Cargo.toml). Both dependencies
# are resolved straight from their published sources; no local praxis checkout
# is required.
#
# Knobs:
#   GATEWAY_PROFILE=release|debug       (default: release)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"

PROFILE="${GATEWAY_PROFILE:-release}"
flag=""
[ "$PROFILE" = "release" ] && flag="--release"
echo "gateway: cargo build ($PROFILE)" >&2
( cd "$DIR" && cargo build $flag >&2 )

bin="$DIR/target/$PROFILE/cpex-praxis-gateway"
[ -x "$bin" ] || { echo "gateway binary not found at $bin" >&2; exit 1; }
printf '%s\n' "$bin"
