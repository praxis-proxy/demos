#!/usr/bin/env bash
# Two Grid sites over llm-d, behind a litellm front door.
#
# site-a is the hub: cert-manager there issues both sites' identities from one
# Grid CA, and this script delivers each to its site, standing in for the ACM or
# OCM policy that does it in a fleet. No enrollment service runs. Membership is
# Local: each site's values list its peers as GridSite records, and no SWIM runs. Peers are
# authorized on their SPIFFE ID, signals travel by direct mTLS pull, and each
# consumer gateway routes with grid_site_route over the operator-published
# serving config.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
GRID_REPO=${GRID_REPO:?path to a praxis-proxy/grid checkout at the release being installed}
CHARTS="$GRID_REPO/charts"
NET=${NET:-grid-llmd-net}
SUBNET=${SUBNET:-10.90.0.0/24}
HUB=site-a
SITES=${SITES:-"site-a site-b"}
METALLB=${METALLB:-https://raw.githubusercontent.com/metallb/metallb/v0.14.9/config/manifests/metallb-native.yaml}
CERT_MANAGER=${CERT_MANAGER:-https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml}

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

echo "== cert-manager on the hub =="
k "$HUB" apply -f "$CERT_MANAGER" >/dev/null
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  k "$HUB" -n cert-manager rollout status "deployment/$d" --timeout=300s >/dev/null
done

echo "== the llm-d layer, one chart per site =="
for s in $SITES; do
  k "$s" create namespace grid --dry-run=client -o yaml | k "$s" apply -f - >/dev/null
  h "$s" upgrade --install llmd-site "$HERE/charts/llmd-site" -n grid \
    --set site="$s" --wait --timeout 300s
done

echo "== identities, issued on the hub =="
# The webhook admits Certificates a little after its rollout reports ready.
for _ in $(seq 1 30); do
  if h "$HUB" upgrade --install grid-enrollment "$CHARTS/grid-enrollment" \
      -n grid-enrollment --create-namespace --values "$HERE/values/hub-grid-enrollment.yaml" >/dev/null 2>&1
  then break; fi
  sleep 5
done
# The issued Secret is grid-<site>, the secretName the hub values give each site.
for s in $SITES; do
  for _ in $(seq 1 60); do
    k "$HUB" -n grid-enrollment get secret "grid-${s}" >/dev/null 2>&1 && break
    sleep 5
  done
  k "$HUB" -n grid-enrollment get secret "grid-${s}" >/dev/null
done

echo "== identities delivered, then an operator and the site topology per site =="
secret_key() { # <ctx> <ns> <secret> <key>: go-template, not jsonpath, since a key like ca.crt has a dot in it.
  k "$1" -n "$2" get secret "$3" -o go-template="{{index .data \"$4\"}}" | base64 -d
}
copy_secret() {
  local from=$1 fromns=$2 name=$3 key=$4 to=$5 tons=$6 target=$7
  secret_key "$from" "$fromns" "$name" "$key" \
    | k "$to" -n "$tons" create secret generic "$target" --from-file="$key"=/dev/stdin \
      --dry-run=client -o yaml | k "$to" apply -f - >/dev/null
}
# Two Secrets cross clusters, the site's identity and the Grid CA, the same two
# an ACM or OCM policy places on every selected cluster in a fleet. The operator
# reads tls.crt and tls.key from grid-site-identity and ca.crt from grid-ca.
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
for s in $SITES; do
  secret_key "$HUB" grid-enrollment "grid-${s}" tls.crt > "$WORK/${s}.crt"
  secret_key "$HUB" grid-enrollment "grid-${s}" tls.key > "$WORK/${s}.key"
  k "$s" -n grid create secret tls grid-site-identity --cert="$WORK/${s}.crt" --key="$WORK/${s}.key" \
    --dry-run=client -o yaml | k "$s" apply -f - >/dev/null
  rm -f "$WORK/${s}.key"
  copy_secret "$HUB" grid-enrollment "grid-${s}" ca.crt "$s" grid grid-ca
  # No --wait: the operator serves nothing until its GridNetwork exists, which grid-site declares next.
  h "$s" upgrade --install grid-operator "$CHARTS/grid-operator" -n grid \
    --values "$HERE/values/${s}-grid-operator.yaml"
  h "$s" upgrade --install grid-site "$CHARTS/grid-site" -n grid \
    --values "$HERE/values/${s}-grid-site.yaml" --wait --timeout 300s
  k "$s" -n grid rollout status deployment/grid-operator --timeout=300s >/dev/null
done

echo "== provider gateway, consumer gateway =="
for s in $SITES; do
  h "$s" upgrade --install provider-gateway "$CHARTS/praxis-gateway" -n grid \
    --values "$HERE/values/${s}-provider-gateway.yaml" --wait --timeout 300s
done
for s in $SITES; do
  h "$s" upgrade --install consumer-gateway "$CHARTS/praxis-gateway" -n grid \
    --values "$HERE/values/${s}-consumer-gateway.yaml" --wait --timeout 300s
done

echo
echo "Topology up. Front door: $HERE/litellm/start-litellm.sh"
