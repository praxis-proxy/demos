#!/usr/bin/env bash
# Front door for the two-site Grid topology.
#
# litellm is the auth boundary: it holds a key store, the master key administers
# it, and callers present a virtual key minted per caller. Grid never sees a
# caller credential, and the model credential is attached at the provider edge.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CTX_A=${CTX_A:-kind-grid-llmd-site-a}
CTX_B=${CTX_B:-kind-grid-llmd-site-b}
NET=${NET:-grid-llmd-net}
MODEL=${MODEL:-Qwen/Qwen3-0.6B}
MASTER_KEY=${MASTER_KEY:-sk-master-grid-llmd}
SALT_KEY=${SALT_KEY:-salt-grid-llmd}
PORT=${PORT:-4000}
NAME=${NAME:-litellm-frontdoor}
DB=${DB:-litellm-db}
CONFIG="$HERE/config.yaml"

lb_ip() {
  kubectl --context "$1" -n grid get svc consumer-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

IP_A=$(lb_ip "$CTX_A")
IP_B=$(lb_ip "$CTX_B")
[[ -n $IP_A && -n $IP_B ]] || { echo "a consumer gateway has no load balancer address" >&2; exit 1; }

# Both sites carry the same model name. litellm picks an entry; Grid picks the
# site that serves it, so this is a front door, not a load balancer.
cat > "$CONFIG" <<YAML
model_list:
  - model_name: ${MODEL}
    litellm_params:
      model: openai/${MODEL}
      api_base: http://${IP_A}:8080/v1
      api_key: unused
    model_info:
      id: site-a-entry
  - model_name: ${MODEL}
    litellm_params:
      model: openai/${MODEL}
      api_base: http://${IP_B}:8080/v1
      api_key: unused
    model_info:
      id: site-b-entry

general_settings:
  master_key: ${MASTER_KEY}

litellm_settings:
  drop_params: true
YAML

podman rm -f "$NAME" "$DB" >/dev/null 2>&1 || true

podman run -d --name "$DB" --network "$NET" \
  -e POSTGRES_USER=litellm -e POSTGRES_PASSWORD=litellm -e POSTGRES_DB=litellm \
  docker.io/library/postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do
  podman exec "$DB" pg_isready -U litellm >/dev/null 2>&1 && break
  sleep 2
done

podman run -d --name "$NAME" --network "$NET" -p "${PORT}:4000" \
  -e LITELLM_MASTER_KEY="$MASTER_KEY" \
  -e LITELLM_SALT_KEY="$SALT_KEY" \
  -e DATABASE_URL="postgresql://litellm:litellm@${DB}:5432/litellm" \
  -v "$CONFIG":/app/config.yaml:ro,Z \
  ghcr.io/berriai/litellm:main-stable \
  --config /app/config.yaml --port 4000 >/dev/null

echo "waiting for the front door"
for _ in $(seq 1 60); do
  curl -sf "http://127.0.0.1:${PORT}/health/readiness" >/dev/null 2>&1 && break
  sleep 5
done

# Mint a caller key. The master key administers; it is not what a caller uses.
CALLER_KEY=$(curl -sf "http://127.0.0.1:${PORT}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  -d "{\"models\":[\"${MODEL}\"],\"key_alias\":\"grid-demo-caller-$RANDOM\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["key"])')

echo "site A entry: http://${IP_A}:8080"
echo "site B entry: http://${IP_B}:8080"
echo "front door:   http://127.0.0.1:${PORT}"
echo "caller key:   ${CALLER_KEY}"
