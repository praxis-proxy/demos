#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Build the demo gateway and echo the binary path on stdout.
#
# The gateway (./gateway) is a thin binary that composes praxis-ai's AI filters
# (mcp classifier, ...) with the CPEX/HIL `policy` filter: it depends on
# praxis-ai's server, enables `cpex-policy-engine`, and `[patch]`es
# praxis-proxy-* to our HIL fork (via `gateway/.praxis`). praxis-ai + the
# feature auto-register both filters — no manual wiring.
#
# Where the praxis fork comes from (first match wins), resolved into the
# gitignored `gateway/.praxis`:
#   PRAXIS_DIR                          path to a local praxis checkout (symlinked)
#   PRAXIS_GIT_URL (+ PRAXIS_GIT_REF)   cloned into .praxis (ref default: feat/hil_apl)
#   existing gateway/.praxis            reused as-is
# Other knobs:
#   GATEWAY_PROFILE=release|debug       (default: release)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"
PRAXIS_LINK="$DIR/.praxis"

# 1. Resolve the praxis fork source into ./gateway/.praxis.
if [ -n "${PRAXIS_DIR:-}" ]; then
  target="$(cd "$PRAXIS_DIR" && pwd)"
  ln -sfn "$target" "$PRAXIS_LINK"
  echo "gateway: .praxis -> $target (PRAXIS_DIR)" >&2
elif [ -n "${PRAXIS_GIT_URL:-}" ]; then
  ref="${PRAXIS_GIT_REF:-feat/hil_apl}"
  if [ -d "$PRAXIS_LINK/.git" ]; then
    echo "gateway: updating .praxis -> $ref ($PRAXIS_GIT_URL)" >&2
    git -C "$PRAXIS_LINK" fetch --quiet --tags --force origin "$ref"
    git -C "$PRAXIS_LINK" checkout --quiet -B "$ref" FETCH_HEAD
  else
    echo "gateway: cloning .praxis <- $PRAXIS_GIT_URL @ $ref" >&2
    rm -rf "$PRAXIS_LINK"
    git clone --quiet --branch "$ref" "$PRAXIS_GIT_URL" "$PRAXIS_LINK"
  fi
elif [ ! -e "$PRAXIS_LINK" ]; then
  echo "fatal: no praxis source for the gateway." >&2
  echo "  Set PRAXIS_DIR=<local praxis checkout> or" >&2
  echo "  PRAXIS_GIT_URL=<url> [PRAXIS_GIT_REF=<ref>] (default ref: feat/hil_apl)." >&2
  echo "  (Once the HIL changes are upstream, drop the [patch] in gateway/Cargo.toml.)" >&2
  exit 1
fi

# 2. Build.
PROFILE="${GATEWAY_PROFILE:-release}"
flag=""
[ "$PROFILE" = "release" ] && flag="--release"
echo "gateway: cargo build ($PROFILE)" >&2
( cd "$DIR" && cargo build $flag >&2 )

bin="$DIR/target/$PROFILE/cpex-praxis-gateway"
[ -x "$bin" ] || { echo "gateway binary not found at $bin" >&2; exit 1; }
printf '%s\n' "$bin"
