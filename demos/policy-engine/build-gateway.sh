#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors
#
# Build the demo gateway and echo the binary path on stdout.
#
# The gateway (./gateway) is a thin binary that composes praxis-ai's AI filters
# (mcp classifier, ...) with the `policy` filter. Since praxis 0.6.0 the
# published `praxis-proxy-filter` carries `policy-engine` in its default
# features, so praxis itself now comes from crates.io and there is no praxis
# checkout to resolve. praxis-ai + the feature auto-register both filters, so
# there is no manual wiring.
#
# One checkout is still needed, at `gateway/.policy`: the two reference plugins
# are unpublished, and they reach the engine by path (see gateway/Cargo.toml).
# Resolved from the first match:
#   PPE_DIR                   path to a local praxis-policy checkout (symlinked)
#   existing gateway/.policy  reused as-is
#   sibling ../praxis-policy  used when there is one
#   otherwise                 clone PPE_GIT_URL @ PPE_GIT_REF (the tag below)
#
# Keep that checkout on the tag matching the engine release praxis depends on.
# A checkout on some other branch links its `praxis-policy-core` against the
# published rest of the engine, which puts two copies of the crate in the graph.
# `check_graph` below fails the build when that happens rather than letting it
# surface as a confusing type error deep in the dependency tree.
#
# Other knobs:
#   GATEWAY_PROFILE=release|debug       (default: release)
set -euo pipefail

# The engine release the gateway resolves from crates.io, and the tag the
# checkout supplying the reference plugins must sit on. Bump together with the
# `praxis-proxy-*` version in gateway/Cargo.toml: praxis and the engine are one
# change split across two repos.
DEFAULT_PPE_REF="v0.3.0"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gateway"
PPE_LINK="$DIR/.policy"

# 1. Resolve the policy engine into ./gateway/.policy.
#
# A symlink is never fetched into. `.policy` pointing at somebody's working
# checkout means `git checkout` here would move their branch out from under them.
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

# 2. Check the resolved dependency graph before trusting a build from it.
#
# Every failure this catches otherwise surfaces as a type error hundreds of
# lines into a cargo build, naming a trait or struct rather than the pin that
# actually drifted. Cheap to check, expensive to diagnose from the compiler.
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

# A stale lock is the common case and cargo cannot always migrate one across a
# pin bump: it drops the patches and resolves an older graph instead. Rebuild
# the lock once and re-check before treating it as a real version conflict.
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

# cargo may have re-resolved during the build; a patch dropped there is just as
# silent, so check what was actually compiled rather than what was planned.
if ! check_graph; then
  echo "gateway: the build re-resolved into an incoherent graph." >&2
  explain_graph
  exit 1
fi

bin="$DIR/target/$PROFILE/policy-engine-gateway"
[ -x "$bin" ] || { echo "gateway binary not found at $bin" >&2; exit 1; }
printf '%s\n' "$bin"
