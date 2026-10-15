#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
public_key="$DEMO_DIR/.state/demo-public.pem"
template="$DEMO_DIR/policy.yaml.template"
output="$DEMO_DIR/.state/policy.yaml"

[ -s "$public_key" ] || { echo "missing demo public key: run scripts/mint-jwt.sh" >&2; exit 1; }

awk -v key_file="$public_key" '
  /^__DEMO_PUBLIC_KEY__$/ {
    while ((getline line < key_file) > 0) print "              " line
    close(key_file)
    next
  }
  { print }
' "$template" >"$output"
chmod 600 "$output"
