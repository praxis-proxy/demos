#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Build the gateway and print its binary path.
#
# Resolve gateway/.policy from PPE_DIR, an existing checkout, a sibling
# praxis-policy directory, or PPE_GIT_URL at PPE_GIT_REF (default below).
# The policy checkout must match the engine version required by Praxis.
# GATEWAY_PROFILE=debug selects a debug build; release is the default.
set -euo pipefail

# Policy tag for the reference plugins. Keep compatible with gateway/Cargo.toml.
DEFAULT_PPE_REF="v0.4.1"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"
PPE_LINK="$DIR/.policy"

# Reuse symlinks without fetching or changing the source checkout.
if [ -n "${PPE_DIR:-}" ]; then
  target="$(cd "$PPE_DIR" && pwd)"
  ln -sfn "$target" "$PPE_LINK"
  echo "gateway: .policy -> $target (PPE_DIR)" >&2
elif [ -L "$PPE_LINK" ]; then
  echo "gateway: .policy -> $(readlink "$PPE_LINK") (existing symlink)" >&2
elif [ -d "$PPE_LINK/.git" ] && [ -z "${PPE_GIT_URL:-}" ]; then
  echo "gateway: .policy (existing clone, reused as-is)" >&2
elif sibling="$(cd "$DIR/../../../../praxis-policy" 2>/dev/null && pwd)"; then
  ln -sfn "$sibling" "$PPE_LINK"
  echo "gateway: .policy -> $sibling (sibling checkout)" >&2
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

# Check for duplicate crates and unused patches before building.
count_pkg() { grep -c "^name = \"$1\"\$" "$DIR/Cargo.lock" 2>/dev/null || true; }

check_graph() {
  local lock="$DIR/Cargo.lock" problems=0
  [ -f "$lock" ] || return 0

  # Cargo drops a `[patch]` it cannot apply and resolves the registry copy
  # instead, silently. The lock records the ones it skipped.
  if grep -q '^\[\[patch.unused\]\]' "$lock"; then
    echo "gateway:   unused [patch] entries:" >&2
    grep -A2 '^\[\[patch.unused\]\]' "$lock" | grep '^name' | sed 's/^/gateway:     /' >&2
    problems=1
  fi

  # Two copies of a crate that defines a trait mean two incompatible traits.
  # praxis-policy-core is the one that breaks host plugin registration.
  local n
  for pkg in praxis-policy-core praxis-proxy-core quixotic-plecostomus-core; do
    n="$(count_pkg "$pkg")"
    if [ "${n:-0}" -gt 1 ]; then
      echo "gateway:   $n copies of $pkg in the graph:" >&2
      grep -A1 "^name = \"$pkg\"\$" "$lock" | grep '^version' | sed 's/^/gateway:     /' >&2
      problems=1
    fi
  done
  return $problems
}

explain_graph() {
  cat >&2 <<'MSG'
gateway:
gateway: What this usually means:
gateway:   praxis-policy-core x2      .policy is not on the tag matching the
gateway:                              praxis-policy release praxis depends on.
gateway:                              Check DEFAULT_PPE_REF against the `ppe`
gateway:                              version in the praxis release.
gateway:   quixotic-plecostomus-core x2
gateway:                              the praxis-ai rev and the praxis release
gateway:                              disagree on the pingora fork. Bump the
gateway:                              praxis-ai rev in gateway/Cargo.toml.
gateway:   praxis-proxy-core x2       praxis-ai pins praxis by git; the
gateway:                              [patch] redirecting it to the published
gateway:                              version is missing or did not apply.
MSG
}

# Regenerate a stale lockfile once before reporting a version conflict.
if ! check_graph; then
  echo "gateway: dependency graph is incoherent, regenerating Cargo.lock" >&2
  ( cd "$DIR" && cargo generate-lockfile >&2 )
  if ! check_graph; then
    echo "gateway: still incoherent after regenerating the lock." >&2
    explain_graph
    exit 1
  fi
  echo "gateway: graph coherent after regenerating" >&2
fi

# 3. Build.
PROFILE="${GATEWAY_PROFILE:-release}"
flag=""
[ "$PROFILE" = "release" ] && flag="--release"
echo "gateway: cargo build ($PROFILE)" >&2
( cd "$DIR" && cargo build $flag >&2 )

# Check again in case Cargo changed the dependency graph during the build.
if ! check_graph; then
  echo "gateway: the build re-resolved into an incoherent graph." >&2
  explain_graph
  exit 1
fi

bin="$DIR/target/$PROFILE/policy-engine-gateway"
[ -x "$bin" ] || { echo "gateway binary not found at $bin" >&2; exit 1; }
printf '%s\n' "$bin"
