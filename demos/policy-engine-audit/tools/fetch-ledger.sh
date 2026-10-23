#!/bin/bash
# Check out the ARE immutable ledger this demo feeds, at a pinned commit,
# into .ledger/ (git-ignored). The compose file builds the ledger image from
# it and mounts its migrations; the scenarios run its CPEX adapter and proof
# explorer from the same checkout, so the three never drift apart.
#
#   tools/fetch-ledger.sh          # prints the checkout path
set -euo pipefail
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$DEMO_DIR/.ledger"
# v0.2.0 — canonical upstream
REPO="https://github.com/jkershawrh/are-immutable-ledger.git"
COMMIT="544528f23cafce547c032936e07df23f9d41d677"

if [ "$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)" != "$COMMIT" ]; then
    rm -rf "$DEST"
    git init -q "$DEST"
    git -C "$DEST" remote add origin "$REPO"
    git -C "$DEST" fetch -q --depth 1 origin "$COMMIT"
    git -C "$DEST" checkout -q FETCH_HEAD
fi
echo "$DEST"
