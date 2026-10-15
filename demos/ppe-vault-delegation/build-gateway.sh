#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATEWAY_DIR="$DEMO_DIR/gateway"
PPE_LINK="$GATEWAY_DIR/.policy"
PPE_CHECKOUT="$GATEWAY_DIR/.policy-checkout"
PPE_GIT_URL="${PPE_GIT_URL:-https://github.com/mkoushni/policy.git}"
# Last reviewed PR #168 commit when this demo was created. Replace with the
# released tag after https://github.com/praxis-proxy/policy/pull/168 merges.
PPE_GIT_REF="${PPE_GIT_REF:-a039de08d586609d89376fbae8dfaa24fe5f9e91}"

if [ -d "$PPE_LINK/.git" ] && [ ! -e "$PPE_CHECKOUT" ]; then
  # Migrate checkouts made by an earlier version of this script. Keeping the
  # clone separate lets PPE_DIR replace only the symlink, never user files.
  mv "$PPE_LINK" "$PPE_CHECKOUT"
fi

if [ -n "${PPE_DIR:-}" ]; then
  target="$(cd "$PPE_DIR" && pwd)"
  ln -sfn "$target" "$PPE_LINK"
  printf 'gateway: PPE checkout -> %s\n' "$target" >&2
else
  if [ -d "$PPE_CHECKOUT/.git" ]; then
    git -C "$PPE_CHECKOUT" fetch --quiet origin "$PPE_GIT_REF"
    git -C "$PPE_CHECKOUT" checkout --quiet --detach FETCH_HEAD
  else
    git clone --quiet "$PPE_GIT_URL" "$PPE_CHECKOUT"
    git -C "$PPE_CHECKOUT" fetch --quiet origin "$PPE_GIT_REF"
    git -C "$PPE_CHECKOUT" checkout --quiet --detach "$PPE_GIT_REF"
  fi
  ln -sfn "$PPE_CHECKOUT" "$PPE_LINK"
  printf 'gateway: PPE checkout -> %s\n' "$PPE_CHECKOUT" >&2
fi

profile="${GATEWAY_PROFILE:-debug}"
args=()
if [ "$profile" = "release" ]; then
  args+=(--release)
fi

(cd "$GATEWAY_DIR" && rustup run 1.96.0 cargo build "${args[@]}") >&2
binary="$GATEWAY_DIR/target/$profile/ppe-vault-demo-gateway"
[ -x "$binary" ] || { printf 'gateway binary missing: %s\n' "$binary" >&2; exit 1; }
printf '%s\n' "$binary"
