#!/usr/bin/env bash
# Resolve (and build, if needed) the Praxis gateway binary this demo runs on,
# then print its path to stdout.
#
# This demo uses the experimental `ratelimit/limitador` plugin (PPE, embedded
# in-memory Limitador). As of Praxis core v0.8.0 everything it needs is RELEASED:
#
#   * core v0.8.0 pins PPE v0.6.0 (which carries the merged ratelimit plugin);
#   * core's `praxis` binary ships the plugin in its DEFAULT `policy-builtins`
#     bundle (feature `policy-experimental-ratelimit`), so no feature overlay or
#     source vendoring is needed — unlike earlier 0.7.5/0.5.0 combinations;
#   * core's `policy` filter already invokes `ratelimit.post_identity` after
#     identity resolution (the former praxis#1478 host wiring is upstream).
#
# The ONE build-time requirement that remains: the plugin contains Limitador's
# panic on a bad CEL condition via catch_unwind, so its factory REFUSES TO LOAD
# on a `panic = "abort"` build. Core's release profile pins `panic = "abort"`, so
# this script builds with `panic = "unwind"` (via CARGO_PROFILE_RELEASE_PANIC).
#
# Praxis is NOT vendored in this repo — it's a separate workspace. This script
# decides WHERE to get it from. By default it clones the public repo at the
# pinned ref below; point it at a sibling checkout or any git URL + ref instead.
#
# Source resolution (first match wins):
#   1. PRAXIS_BIN      path to an already-built praxis binary → used as-is
#                      (you are responsible for having built it panic=unwind
#                      with the ratelimit plugin)
#   2. PRAXIS_DIR      path to a praxis checkout → built in place
#   3. PRAXIS_GIT_URL  clone this URL @ PRAXIS_GIT_REF, then build
#   4. (default)       sibling ../../../praxis if present, else clone the
#                      public repo at PRAXIS_GIT_REF
#
# Env:
#   PRAXIS_GIT_URL  git remote to clone (default below)
#   PRAXIS_GIT_REF  branch / tag / commit to build (default: the pinned tag
#                   below; pass `main` to track the branch instead)
#   PRAXIS_SRC      clone destination (default: ./.praxis-src, git-ignored)
#
# Progress goes to stderr; ONLY the binary path is printed to stdout, so callers
# can capture it directly:
#
#   GATEWAY_BIN="$(./build-praxis.sh)"
set -euo pipefail
cd "$(dirname "$0")"

DEFAULT_GIT_URL="https://github.com/praxis-proxy/praxis.git"
# A released tag, not a branch. The ratelimit plugin needs the host wiring and
# the PPE v0.6.0 pin that first ship together in core v0.8.0; pinning a tag keeps
# this demo reproducible as praxis main moves. PRAXIS_GIT_REF=main opts into the
# branch.
DEFAULT_GIT_REF="v0.8.0"
# This script lives at demos/ratelimit-agents-requests/, so a praxis checkout
# sitting beside praxis-demos/ is three levels up.
SIBLING="../../../praxis"
REL_BIN="target/release/praxis"
# The core binary (crate praxis-proxy). The plugin is in its default feature set;
# naming the feature explicitly documents the dependency and is a no-op if it is
# already on by default.
RATELIMIT_FEATURE="policy-experimental-ratelimit"

log() { printf '\033[1;34m[build-praxis]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[build-praxis] %s\033[0m\n' "$*" >&2; exit 1; }

build_in() {
  # Build the praxis binary with the ratelimit plugin, panic=unwind, in $1;
  # echo the binary path.
  local dir="$1"
  [ -f "$dir/Cargo.toml" ] || die "no Cargo.toml in $dir — not a praxis checkout"
  log "cargo build --release -p praxis-proxy --features $RATELIMIT_FEATURE  (in $dir)"
  log "forcing panic=unwind (the ratelimit plugin refuses to load on an aborting build)"
  # CARGO_PROFILE_RELEASE_PANIC overrides the manifest's [profile.release] panic
  # setting without mutating the checkout (works for a sibling source tree too).
  ( cd "$dir" \
      && CARGO_PROFILE_RELEASE_PANIC=unwind \
         cargo build --release -p praxis-proxy --features "$RATELIMIT_FEATURE" >&2 )
  local bin="$dir/$REL_BIN"
  [ -x "$bin" ] || die "expected binary not found at $bin"
  log "built $bin"
  printf '%s\n' "$bin"
}

clone_or_update() {
  # Ensure $PRAXIS_SRC is a checkout of $1 at ref $2, then echo its path.
  local url="$1" ref="$2" src="${PRAXIS_SRC:-.praxis-src}"
  if [ -d "$src/.git" ]; then
    log "updating $src → $ref ($url)"
    git -C "$src" fetch --tags --force origin "$ref" 2>/dev/null \
      || git -C "$src" fetch --tags --force origin
    git -C "$src" checkout -q --detach "$ref" 2>/dev/null \
      || git -C "$src" checkout -q --detach FETCH_HEAD
  else
    log "cloning $url @ $ref → $src"
    # --branch takes a branch or tag, never a commit, so clone then detach.
    git clone "$url" "$src"
    git -C "$src" checkout -q --detach "$ref"
  fi
  printf '%s\n' "$src"
}

# 1. Prebuilt binary wins.
if [ -n "${PRAXIS_BIN:-}" ]; then
  [ -x "$PRAXIS_BIN" ] || die "PRAXIS_BIN=$PRAXIS_BIN is not executable"
  log "using prebuilt PRAXIS_BIN=$PRAXIS_BIN"
  printf '%s\n' "$PRAXIS_BIN"
  exit 0
fi

# 2. Explicit checkout dir.
if [ -n "${PRAXIS_DIR:-}" ]; then
  log "using PRAXIS_DIR=$PRAXIS_DIR"
  build_in "$PRAXIS_DIR"
  exit 0
fi

# 3. Explicit git URL → clone + build.
if [ -n "${PRAXIS_GIT_URL:-}" ]; then
  src="$(clone_or_update "$PRAXIS_GIT_URL" "${PRAXIS_GIT_REF:-$DEFAULT_GIT_REF}")"
  build_in "$src"
  exit 0
fi

# 4. Default: prefer a sibling checkout (local dev / unpushed work);
#    otherwise clone the public repo at the default ref.
if [ -f "$SIBLING/Cargo.toml" ]; then
  log "using sibling checkout $SIBLING (set PRAXIS_GIT_URL to build from git instead)"
  build_in "$SIBLING"
  exit 0
fi

log "no sibling checkout; falling back to git ($DEFAULT_GIT_URL @ $DEFAULT_GIT_REF)"
src="$(clone_or_update "$DEFAULT_GIT_URL" "${PRAXIS_GIT_REF:-$DEFAULT_GIT_REF}")"
build_in "$src"
