#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
#
# Build the demo gateway and echo the binary path on stdout.
#
# The gateway (./gateway) is a thin binary that composes praxis-ai's AI filters
# (mcp classifier, ...) with the `policy` filter: it depends on praxis-ai's
# server, enables `policy-engine`, and `[patch]`es praxis-proxy-* to a local
# praxis checkout (via `gateway/.praxis`), because the engine port it needs is
# unreleased. praxis-ai + the feature auto-register both filters — no manual
# wiring.
#
# Where the praxis checkout comes from (first match wins), resolved into the
# gitignored `gateway/.praxis`:
#   PRAXIS_DIR                          path to a local praxis checkout (symlinked)
#   existing gateway/.praxis            reused as-is
#   otherwise                           clone PRAXIS_GIT_URL @ PRAXIS_GIT_REF,
#                                       defaulting to upstream praxis on main
#
# Other knobs:
#   GATEWAY_PROFILE=release|debug       (default: release)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"
PRAXIS_LINK="$DIR/.praxis"

# 1. Resolve the praxis source into ./gateway/.praxis.
#
# A symlink is never fetched into. `.praxis` pointing at somebody's working
# checkout means `git checkout` here would move their branch out from under them.
if [ -n "${PRAXIS_DIR:-}" ]; then
  target="$(cd "$PRAXIS_DIR" && pwd)"
  ln -sfn "$target" "$PRAXIS_LINK"
  echo "gateway: .praxis -> $target (PRAXIS_DIR)" >&2
elif [ -L "$PRAXIS_LINK" ]; then
  echo "gateway: .praxis -> $(readlink "$PRAXIS_LINK") (existing symlink)" >&2
elif [ -d "$PRAXIS_LINK/.git" ] && [ -z "${PRAXIS_GIT_URL:-}" ]; then
  echo "gateway: .praxis (existing clone, reused as-is)" >&2
else
  url="${PRAXIS_GIT_URL:-https://github.com/praxis-proxy/praxis.git}"
  ref="${PRAXIS_GIT_REF:-main}"
  if [ -d "$PRAXIS_LINK/.git" ]; then
    echo "gateway: updating .praxis -> $ref ($url)" >&2
    git -C "$PRAXIS_LINK" fetch --quiet --tags --force origin "$ref"
    git -C "$PRAXIS_LINK" checkout --quiet -B "$ref" FETCH_HEAD
  else
    echo "gateway: cloning .praxis <- $url @ $ref" >&2
    rm -rf "$PRAXIS_LINK"
    git clone --quiet --branch "$ref" "$url" "$PRAXIS_LINK"
  fi
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
