#!/usr/bin/env bash
# Run a Grid quickstart demo using Grid's Forge and xtask binaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage: run-grid-demo.sh <demo-dir> [xtask-flags...]

Environment:
  GRID_REPO          Path to a local praxis-proxy/grid checkout.
                     When unset, Grid is cloned into .grid-checkout/.
  FORGE_CONFIG_NAME  Forge config filename within <demo-dir> (default: forge.yaml).
                     Lets a demo ship multiple Forge config flavors side by
                     side (e.g. forge-kv-cache.yaml) without duplicating its
                     resources/configs assets.

Image overrides (optional):
  GRID_XTASK_GATEWAY_IMAGE
  GRID_XTASK_OPERATOR_IMAGE
  GRID_XTASK_VCR_IMAGE
  GRID_XTASK_IMAGE_PULL_POLICY
EOF
    exit 1
}

[[ $# -lt 1 ]] && usage

DEMO_DIR="$(cd "$1" && pwd)"
shift
DEMO_NAME="$(basename "${DEMO_DIR}")"

# Public demos are cold-startable by default. Local development images remain
# available by setting these variables explicitly and using pull policy Never.
export GRID_XTASK_GATEWAY_IMAGE="${GRID_XTASK_GATEWAY_IMAGE:-ghcr.io/praxis-proxy/grid-ai-rollup:v0.1.3}"
export GRID_XTASK_OPERATOR_IMAGE="${GRID_XTASK_OPERATOR_IMAGE:-ghcr.io/praxis-proxy/grid-operator:v0.1.3}"
export GRID_XTASK_OVERLAY_SYNC_IMAGE="${GRID_XTASK_OVERLAY_SYNC_IMAGE:-ghcr.io/praxis-proxy/grid-overlay-sync:v0.1.3}"
export GRID_XTASK_VCR_IMAGE="${GRID_XTASK_VCR_IMAGE:-ghcr.io/neuralmagic/vllm-vcr:vllm0.23}"
export GRID_XTASK_IMAGE_PULL_POLICY="${GRID_XTASK_IMAGE_PULL_POLICY:-IfNotPresent}"

# Resolve or clone Grid repository.
if [[ -z "${GRID_REPO:-}" ]]; then
    GRID_CLONE="${SCRIPT_DIR}/../.grid-checkout"
    if [[ ! -d "${GRID_CLONE}" ]]; then
        echo "GRID_REPO not set -- cloning praxis-proxy/grid into ${GRID_CLONE}..." >&2
        git clone --depth 1 https://github.com/praxis-proxy/grid.git "${GRID_CLONE}"
    fi
    GRID_REPO="${GRID_CLONE}"
fi
GRID_REPO="$(cd "${GRID_REPO}" && pwd)"

if [[ ! -f "${GRID_REPO}/Cargo.toml" ]]; then
    echo "error: GRID_REPO (${GRID_REPO}) does not contain a Cargo.toml" >&2
    exit 1
fi

# Map demo name to xtask subcommand.
case "${DEMO_NAME}" in
    grid-glb-demo)           SUBCOMMAND="run-grid-glb-demo" ;;
    grid-llmd-pool-metrics)  SUBCOMMAND="run-grid-llmd-pool-metrics-demo" ;;
    grid-combined-site)      SUBCOMMAND="run-grid-combined-site-demo" ;;
    *)
        echo "error: unknown demo '${DEMO_NAME}'" >&2
        exit 1
        ;;
esac

FORGE_CONFIG="${DEMO_DIR}/${FORGE_CONFIG_NAME:-forge.yaml}"
if [[ ! -f "${FORGE_CONFIG}" ]]; then
    echo "error: forge config not found: ${FORGE_CONFIG}" >&2
    exit 1
fi

if [[ -n "${GRID_DEMO_ENTRYPOINT:-}" ]]; then
    echo "Entrypoint:   ${GRID_DEMO_ENTRYPOINT}" >&2
fi
echo "Demo:         ${DEMO_NAME}" >&2
echo "Subcommand:   ${SUBCOMMAND}" >&2
echo "Forge config: ${FORGE_CONFIG}" >&2
echo "Demo root:    ${DEMO_DIR}" >&2
echo "Grid repo:    ${GRID_REPO}" >&2
echo "" >&2

# Build tooling and run from the Grid workspace root.
cd "${GRID_REPO}"
cargo build -p forge -p xtask 2>&1
exec cargo xtask env "${SUBCOMMAND}" --forge-config "${FORGE_CONFIG}" "$@"
