#!/bin/bash
# policy-engine-audit demo: Praxis gateway -> OCSF audit sink -> ARE ledger.
#
#   ./run-demo.sh               business story: scenarios 01-04 (~10 minutes)
#   ./run-demo.sh --deep-dive   same, with record fields shown, then 05-06
#                               (restart epoch, tamper and loss)
#
# Env:
#   SKIP_COMPOSE=1      services are already up (or run outside Docker)
#   KEYCLOAK_IMAGE=...  override the Keycloak image (default quay.io)
#   GATEWAY_LAUNCHER=   command prefix for the gateway (see tools/gateway.sh)
set -euo pipefail
trap 'echo "run-demo: failed at line $LINENO" >&2' ERR

DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DEMO_DIR/scenarios/_lib.sh"

DEEP=0
[ "${1:-}" = "--deep-dive" ] && DEEP=1
export DEEP_DIVE=$DEEP

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Praxis audit demo: every agent tool call, provably on record${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════════${RESET}"

# ─── Preflight ──────────────────────────────────────────────────
for tool in cargo curl docker git jq openssl python3; do
    command -v "$tool" >/dev/null || fail "$tool is required"
done
"$DEMO_DIR/tools/fetch-ledger.sh" >/dev/null
ok "ledger checkout at .ledger ($(git -C "$REPO_DIR" rev-parse --short HEAD))"
python3 -c "import grpc, google.protobuf" 2>/dev/null ||
    fail "python3 needs grpcio and protobuf: pip install -r .ledger/adapters/cpex/requirements.txt"

# ─── Signing key (path only: the sink refuses inline keys) ──────
mkdir -p "$DEMO_DIR/keys" "$OUT"
if [ ! -f "$DEMO_DIR/keys/ocsf-signing.pem" ]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "$DEMO_DIR/keys/ocsf-signing.pem" 2>/dev/null
    openssl pkey -in "$DEMO_DIR/keys/ocsf-signing.pem" -pubout \
        -out "$DEMO_DIR/keys/ocsf-signing.pub.pem"
    ok "generated the gateway's P-256 signing key (keys/, git-ignored)"
fi

# ─── Services ───────────────────────────────────────────────────
step "Starting services"
if [ "${SKIP_COMPOSE:-0}" != "1" ]; then
    (cd "$DEMO_DIR" && docker compose up -d --build 2>&1 | tail -2)
fi
wait_for() {
    for _ in $(seq 1 90); do curl -sf "$2" >/dev/null 2>&1 && { ok "$1"; return; }; sleep 2; done
    fail "$1 did not come up ($2)"
}
wait_for "ARE ledger"     http://localhost:18080/readyz
wait_for "Keycloak"       "$KEYCLOAK_URL/realms/$REALM/.well-known/openid-configuration"
wait_for "HR MCP server"  "$HR_MCP_URL/healthz"
curl -sf "$HR_MCP_URL/healthz" >/dev/null

# ─── Gateway ────────────────────────────────────────────────────
step "Building and starting the Praxis gateway"
(cd "$DEMO_DIR/gateway" && cargo build --release --quiet)
"$DEMO_DIR/tools/gateway.sh" stop || true
# Each run starts a fresh record file.
[ -f "$GATEWAY_STDERR" ] && mv "$GATEWAY_STDERR" "$GATEWAY_STDERR.$(date +%s)"
"$DEMO_DIR/tools/gateway.sh" start
ok "gateway on 127.0.0.1:8090 (records: out/gateway.stderr)"

# ─── Scenarios ──────────────────────────────────────────────────
for s in 01-hr-allowed 02-engineer-denied 03-injection-blocked 04-ssn-redacted; do
    bash "$SCENARIO_DIR/$s.sh"
done
if [ "$DEEP" = "1" ]; then
    bash "$SCENARIO_DIR/05-restart.sh"
    bash "$SCENARIO_DIR/06-tamper-and-loss.sh"
fi

# ─── Close ──────────────────────────────────────────────────────
title "Verifying everything"
VALIDATOR="$("$DEMO_DIR/tools/fetch-validator.sh")"
records > "$OUT/export.ndjson"
echo -e "  ${BOLD}AID-EMIT-1 validator${RESET} (fingerprints, chain, DSSE signatures, stream density)"
python3 -I "$VALIDATOR" "$OUT/export.ndjson" --key "$DEMO_DIR/keys/ocsf-signing.pub.pem" |
    tail -1 | sed 's/^/    /'
echo -e "  ${BOLD}ARE ledger${RESET} (independent hash chain over the same records)"
python3 "$REPO_DIR/proof-explorer/proof.py" --endpoint "$LEDGER_GRPC" verify --all 2>&1 |
    grep -E "All .*chains|INVALID" | sed 's/^/    /'

echo ""
echo "  Every ruling the gateway made, allow, deny or modify, is an OCSF event a SIEM"
echo "  ingests as-is, signed by the gateway and receipted by a ledger that does not"
echo "  have to trust it."
echo ""
echo -e "  ${DIM}Stop: tools/gateway.sh stop && docker compose down -v${RESET}"
echo ""
