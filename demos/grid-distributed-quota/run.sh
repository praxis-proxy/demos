#!/usr/bin/env bash
set -euo pipefail
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$(dirname "${DEMO_DIR}")/../scripts/run-grid-demo.sh" "${DEMO_DIR}" "$@"
