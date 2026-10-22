#!/usr/bin/env bash
# Two Grid sites over llm-d, behind a litellm front door.
#
# site-a is the hub: it runs enrollment, so both sites get their identity from
# the Grid CA rather than from a hand-minted certificate. Peers are authorized on
# their SPIFFE ID, signals travel by direct mTLS pull, and each consumer gateway
# routes with grid_site_route over the operator-published serving config.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GRID_REPO=${GRID_REPO:?path to a praxis-proxy/grid checkout at the release being installed}
CHARTS="$GRID_REPO/charts"
NET=${NET:-grid-llmd-net}
SUBNET=${SUBNET:-10.90.0.0/24}
HUB=site-a
SITES=${SITES:-"site-a site-b"}
METALLB=${METALLB:-https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml}
ENROLL_HOST=enroll.grid.demo
ENROLL_IP=10.90.0.205

# One pool per site. A shared pool on a shared L2 network hands the same address
# to both clusters, and the second claimant silently wins.
declare -A LB_RANGES=(
  [site-a]="10.90.0.200-10.90.0.219"
  [site-b]="10.90.0.220-10.90.0.239"
)

ctx() { echo "kind-grid-llmd-$1"; }
k()   { kubectl --context "$(ctx "$1")" "${@:2}"; }
h()   { helm --kube-context "$(ctx "$1")" "${@:2}"; }

echo "== podman network $NET =="
podman network exists "$NET" 2>/dev/null || podman network create --subnet "$SUBNET" "$NET"

echo "== kind clusters =="
for s in $SITES; do
  kind get clusters 2>/dev/null | grep -qx "grid-llmd-$s" \
    || KIND_EXPERIMENTAL_PODMAN_NETWORK="$NET" kind create cluster --name "grid-llmd-$s"
done

echo "== MetalLB =="
for s in $SITES; do
  k "$s" apply -f "$METALLB"
  k "$s" -n metallb-system wait --for=condition=available deployment/controller --timeout=180s
  k "$s" -n metallb-system wait --for=condition=ready pod -l component=speaker --timeout=180s
  for _ in $(seq 1 30); do
    if k "$s" apply -f - <<EOF >/dev/null 2>&1
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: { name: grid-llmd, namespace: metallb-system }
spec: { addresses: [ ${LB_RANGES[$s]} ] }
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: { name: grid-llmd, namespace: metallb-system }
spec: { ipAddressPools: [ grid-llmd ] }
EOF
    then break; fi
    sleep 5
  done
  k "$s" -n metallb-system get ipaddresspool grid-llmd >/dev/null
done

echo "== enrollment host resolves in both clusters =="
for s in $SITES; do
  k "$s" -n kube-system get configmap coredns -o yaml \
    | python3 -c "
import sys,yaml
d=yaml.safe_load(sys.stdin)
cf=d['data']['Corefile']
if '$ENROLL_HOST' not in cf:
    cf=cf.replace('ready', 'ready\n    hosts {\n        $ENROLL_IP $ENROLL_HOST\n        fallthrough\n    }',1)
    d['data']['Corefile']=cf
print(yaml.safe_dump(d))" | k "$s" apply -f - >/dev/null
  k "$s" -n kube-system rollout restart deployment/coredns >/dev/null
done

echo "== the llm-d layer, one chart per site =="
for s in $SITES; do
  k "$s" create namespace grid --dry-run=client -o yaml | k "$s" apply -f - >/dev/null
  h "$s" upgrade --install llmd-site "$HERE/charts/llmd-site" -n grid \
    --set site="$s" --wait --timeout 300s
done

echo "== enrollment on the hub =="
h "$HUB" upgrade --install grid-enrollment "$CHARTS/grid-enrollment" \
  -n grid-enrollment --create-namespace --values "$HERE/values/hub-grid-enrollment.yaml" \
  --wait --timeout 300s

echo "== operators, each enrolling for its own identity =="
copy_secret() {
  local from=$1 fromns=$2 name=$3 key=$4 to=$5 tons=$6 target=$7
  # go-template, not jsonpath: a key like ca.crt has a dot in it.
  k "$from" -n "$fromns" get secret "$name" -o go-template="{{index .data \"$key\"}}" | base64 -d \
    | k "$to" -n "$tons" create secret generic "$target" --from-file="$key"=/dev/stdin \
      --dry-run=client -o yaml | k "$to" apply -f - >/dev/null
}
# One SWIM key for the grid, created once on the hub and copied to each site.
if ! k "$HUB" -n grid get secret grid-swim-key >/dev/null 2>&1; then
  head -c 32 /dev/urandom | k "$HUB" -n grid create secret generic grid-swim-key --from-file=key=/dev/stdin
fi
for s in $SITES; do
  copy_secret "$HUB" grid-enrollment grid-ca-bundle ca.crt "$s" grid grid-ca-bundle
  copy_secret "$HUB" grid-enrollment "grid-invite-${s}" token "$s" grid "grid-invite-${s}"
  k "$s" -n grid label secret "grid-invite-${s}" "grid.praxis.fast/site=${s}" --overwrite >/dev/null
  [[ $s == "$HUB" ]] || copy_secret "$HUB" grid grid-swim-key key "$s" grid grid-swim-key
  h "$s" upgrade --install grid-operator "$CHARTS/grid-operator" -n grid \
    --values "$HERE/values/${s}-grid-operator.yaml" --wait --timeout 300s
  echo "  waiting for ${s} to enroll"
  for _ in $(seq 1 60); do
    k "$s" -n grid get secret grid-site-identity >/dev/null 2>&1 && break
    sleep 5
  done
  k "$s" -n grid get secret grid-site-identity >/dev/null
done

echo "== site topology, provider gateway, consumer gateway =="
for s in $SITES; do
  h "$s" upgrade --install grid-site "$CHARTS/grid-site" -n grid \
    --values "$HERE/values/${s}-grid-site.yaml" --wait --timeout 300s
  h "$s" upgrade --install provider-gateway "$CHARTS/praxis-gateway" -n grid \
    --values "$HERE/values/${s}-provider-gateway.yaml" --wait --timeout 300s
done
for s in $SITES; do
  h "$s" upgrade --install consumer-gateway "$CHARTS/praxis-gateway" -n grid \
    --values "$HERE/values/${s}-consumer-gateway.yaml" --wait --timeout 300s
done

echo
echo "Topology up. Front door: $HERE/litellm/start-litellm.sh"
