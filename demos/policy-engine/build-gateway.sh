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
#                                       defaulting to the pinned commit below
#
# The default ref is a commit, not a branch. praxis main moves, and the demo
# builds it from source, so tracking a branch means the demo can break without
# anything here changing. PRAXIS_GIT_REF=main opts back into tracking.
#
# Other knobs:
#   GATEWAY_PROFILE=release|debug       (default: release)
set -euo pipefail

# praxis main @ #943, the commit that moved the policy filter onto the Praxis
# Policy Engine. Verified with this demo end to end. Bump deliberately.
DEFAULT_PRAXIS_REF="c9c2a46898ebd47f58cffde5865f9e976078fa6e"

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
  ref="${PRAXIS_GIT_REF:-$DEFAULT_PRAXIS_REF}"
  if [ -d "$PRAXIS_LINK/.git" ]; then
    echo "gateway: updating .praxis -> $ref ($url)" >&2
    git -C "$PRAXIS_LINK" fetch --quiet --tags --force origin "$ref" 2>/dev/null \
      || git -C "$PRAXIS_LINK" fetch --quiet --tags --force origin
    # Detach rather than -B: a commit ref is not a branch name.
    git -C "$PRAXIS_LINK" checkout --quiet --detach "$ref" 2>/dev/null \
      || git -C "$PRAXIS_LINK" checkout --quiet --detach FETCH_HEAD
  else
    echo "gateway: cloning .praxis <- $url @ $ref" >&2
    rm -rf "$PRAXIS_LINK"
    # --branch takes a branch or tag, never a commit, so clone then detach.
    git clone --quiet "$url" "$PRAXIS_LINK"
    git -C "$PRAXIS_LINK" checkout --quiet --detach "$ref"
  fi
  echo "gateway: .praxis at $(git -C "$PRAXIS_LINK" rev-parse --short HEAD)" >&2
fi

# 2. Build.
PROFILE="${GATEWAY_PROFILE:-release}"
flag=""
[ "$PROFILE" = "release" ] && flag="--release"
echo "gateway: cargo build ($PROFILE)" >&2
( cd "$DIR" && cargo build $flag >&2 )

bin="$DIR/target/$PROFILE/policy-engine-gateway"
[ -x "$bin" ] || { echo "gateway binary not found at $bin" >&2; exit 1; }
printf '%s\n' "$bin"
