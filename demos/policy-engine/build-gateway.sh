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
# The policy engine needs a checkout too, at `gateway/.policy`, because 0.1.1 is
# unreleased and cargo honours `[patch]` only in the workspace root it is
# building: praxis patching the engine to a sibling path does nothing from here,
# so the gateway names those crates itself (see gateway/Cargo.toml).
#
# It is not a second thing to point at, though. praxis reads the engine as
# `../praxis-policy`, so once .praxis is resolved the engine is its sibling and
# .policy is derived from it. PPE_DIR overrides, and a clone is the fallback when
# there is no sibling to find.
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

# The engine revision that praxis ref was ported onto. Bump the two together:
# praxis 0.1.1 and engine 0.1.1 are one change split across two repos, and a
# mismatched pair fails to compile rather than misbehaving quietly.
DEFAULT_PPE_REF="main"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"
PRAXIS_LINK="$DIR/.praxis"
PPE_LINK="$DIR/.policy"

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

# 1b. Resolve the policy engine into ./gateway/.policy.
#
# Derived from .praxis rather than asked for separately: praxis's own manifest
# reads the engine as `../praxis-policy`, so whoever pointed .praxis at a
# checkout already said where the engine is. Following the same relative path
# keeps the two from disagreeing about which engine praxis was built against.
if [ -n "${PPE_DIR:-}" ]; then
  target="$(cd "$PPE_DIR" && pwd)"
  ln -sfn "$target" "$PPE_LINK"
  echo "gateway: .policy -> $target (PPE_DIR)" >&2
elif [ -L "$PPE_LINK" ]; then
  echo "gateway: .policy -> $(readlink "$PPE_LINK") (existing symlink)" >&2
elif [ -d "$PPE_LINK/.git" ] && [ -z "${PPE_GIT_URL:-}" ]; then
  echo "gateway: .policy (existing clone, reused as-is)" >&2
elif sibling="$(cd "$PRAXIS_LINK/../praxis-policy" 2>/dev/null && pwd)"; then
  # `cd` through the symlink, so this is the sibling of what .praxis points at
  # rather than of the link itself.
  ln -sfn "$sibling" "$PPE_LINK"
  echo "gateway: .policy -> $sibling (sibling of .praxis)" >&2
else
  url="${PPE_GIT_URL:-https://github.com/praxis-proxy/policy.git}"
  ref="${PPE_GIT_REF:-$DEFAULT_PPE_REF}"
  if [ -d "$PPE_LINK/.git" ]; then
    echo "gateway: updating .policy -> $ref ($url)" >&2
    git -C "$PPE_LINK" fetch --quiet --tags --force origin "$ref" 2>/dev/null \
      || git -C "$PPE_LINK" fetch --quiet --tags --force origin
    git -C "$PPE_LINK" checkout --quiet --detach "$ref" 2>/dev/null \
      || git -C "$PPE_LINK" checkout --quiet --detach FETCH_HEAD
  else
    echo "gateway: cloning .policy <- $url @ $ref" >&2
    rm -rf "$PPE_LINK"
    git clone --quiet "$url" "$PPE_LINK"
    git -C "$PPE_LINK" checkout --quiet --detach "$ref"
  fi
  echo "gateway: .policy at $(git -C "$PPE_LINK" rev-parse --short HEAD)" >&2
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
