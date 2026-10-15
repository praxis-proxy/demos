#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 Praxis Contributors

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

for command in cargo curl docker git jq openssl python3 rustup; do
  command -v "$command" >/dev/null || { echo "missing required command: $command" >&2; exit 1; }
done
docker compose version >/dev/null

mkdir -p .state
chmod 700 .state

if [ -s .state/gateway.pid ] && kill -0 "$(<.state/gateway.pid)" 2>/dev/null; then
  echo "gateway is already running; run ./down.sh first" >&2
  exit 1
fi

docker compose up -d --build
for service in vault github-bridge; do
  deadline="$(( $(date +%s) + 60 ))"
  until [ "$(docker inspect -f '{{.State.Health.Status}}' "$(docker compose ps -q "$service")")" = healthy ]; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      docker compose logs "$service" >&2
      echo "$service did not become healthy" >&2
      exit 1
    fi
    sleep 1
  done
done

./scripts/mint-jwt.sh alice >/dev/null
./scripts/mint-jwt.sh bob >/dev/null
./vault/setup.sh

gateway="$(./build-gateway.sh)"
nohup "$gateway" -c "$DEMO_DIR/praxis.yaml" >.state/gateway.log 2>&1 &
printf '%s\n' "$!" >.state/gateway.pid

deadline="$(( $(date +%s) + 30 ))"
until curl -sS -o /dev/null http://127.0.0.1:8090/; do
  if ! kill -0 "$(<.state/gateway.pid)" 2>/dev/null; then
    tail -100 .state/gateway.log >&2
    echo "gateway exited before becoming ready" >&2
    exit 1
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    tail -100 .state/gateway.log >&2
    echo "gateway did not become ready" >&2
    exit 1
  fi
  sleep 1
done
kill -0 "$(<.state/gateway.pid)" 2>/dev/null || {
  tail -100 .state/gateway.log >&2
  echo "gateway exited during startup" >&2
  exit 1
}

cat <<'MSG'

Demo services are ready.

1. Enroll a low-permission GitHub token without putting it in shell history:
     ./scripts/enroll.sh alice --from-gh
   or:
     ./scripts/enroll.sh alice

2. Run the three scenarios:
     ./scripts/run-demo.sh

3. Tear everything down:
     ./down.sh
MSG
