#!/usr/bin/env bash
set -euo pipefail
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Intercept --kv-cache to select the kvCachePressure scoring flavor
# (forge-kv-cache.yaml) instead of the default queueDepth flavor
# (forge.yaml). Both share this directory's resources/ and configs/.
args=()
for arg in "$@"; do
    if [[ "${arg}" == "--kv-cache" ]]; then
        export FORGE_CONFIG_NAME="forge-kv-cache.yaml"
        # Keep the flag so xtask records and evaluates the selected flavor.
        args+=("${arg}")
    else
        args+=("${arg}")
    fi
done

exec "$(dirname "${DEMO_DIR}")/../scripts/run-grid-demo.sh" "${DEMO_DIR}" "${args[@]+"${args[@]}"}"
