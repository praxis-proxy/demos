#!/usr/bin/env bash
# Resolve (and build, if needed) the praxis-cpex gateway binary the demo
# runs on :8090, then print its path to stdout.
#
# Praxis is NOT vendored in this repo — it's a separate workspace. This
# script decides WHERE to get it from. By default it builds a sibling
# checkout (../../../praxis); point it at any git URL + ref to build a
# specific branch / tag / commit instead.
#
# Source resolution (first match wins):
#   1. PRAXIS_BIN      path to an already-built praxis binary → used as-is
#   2. PRAXIS_DIR      path to a praxis checkout → built in place
#   3. PRAXIS_GIT_URL  clone this URL @ PRAXIS_GIT_REF, then build
#   4. (default)       sibling ../../../praxis if present, else clone the
#                      public repo at PRAXIS_GIT_REF
#
# Env:
#   PRAXIS_GIT_URL  git remote to clone (default below)
#   PRAXIS_GIT_REF  branch / tag / commit to build (default: main)
#   PRAXIS_SRC      clone destination (default: ./.praxis-src, git-ignored)
#
# Progress goes to stderr; ONLY the binary path is printed to stdout, so
# callers can capture it directly:
#
#   GATEWAY_BIN="$(./build-praxis.sh)"
set -euo pipefail
cd "$(dirname "$0")"

DEFAULT_GIT_URL="https://github.com/praxis-proxy/praxis.git"
DEFAULT_GIT_REF="main"
SIBLING="../../../praxis"
REL_BIN="target/release/praxis"

log() { printf '\033[1;34m[build-praxis]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[build-praxis] %s\033[0m\n' "$*" >&2; exit 1; }

build_in() {
  # Build praxis with the policy engine feature in $1 and echo the binary path.
  local dir="$1"
  [ -f "$dir/Cargo.toml" ] || die "no Cargo.toml in $dir — not a praxis checkout"
  log "cargo build --release --features cpex-policy-engine -p praxis-proxy  (in $dir)"
  ( cd "$dir" && cargo build --release --features cpex-policy-engine -p praxis-proxy >&2 )
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
    git -C "$src" checkout -q "$ref" 2>/dev/null \
      || git -C "$src" checkout -q FETCH_HEAD
  else
    log "cloning $url @ $ref → $src"
    git clone --branch "$ref" "$url" "$src" 2>/dev/null \
      || { git clone "$url" "$src" && git -C "$src" checkout -q "$ref"; }
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
