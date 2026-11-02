# grid-llmd-litellm

Two Grid sites in front of llm-d, behind a litellm front door.

litellm authenticates the caller. Grid picks the site. llm-d picks the pod. The
model credential is attached at the provider gateway, so no caller credential
crosses the grid.

| Box | What runs |
|---|---|
| Front door | litellm, port 4000, holding the key store that mints caller keys |
| AI-GW Grid | praxis-gateway, consumer role, grid_site_route over the serving config |
| Provider edge | praxis-gateway, provider role, peers admitted on their SPIFFE ID |
| Gateway (Envoy) | Envoy, ext_proc filter, ORIGINAL_DST cluster |
| llm-d Router | llm-d-router-endpoint-picker, the ext_proc backend |
| vLLM | llm-d-inference-sim, two pods per site, one InferencePool |

The hub, site-a, issues both identities from one Grid CA with cert-manager and
delivers them. No enrollment service runs and nothing hand-mints a certificate.
Membership is Local: each site's values list its peers as GridSite records, and
no SWIM runs. Signals travel by direct mTLS pull.

Local membership means the grid has no discovery. A site knows exactly the peers
its own configuration lists, and something outside the grid delivers those
GridSite records to every member: here the values files, in a fleet ACM or
GitOps. See "What is managed by hand under Local" below.

## Prerequisites

kubectl, helm, kind, podman, and a grid checkout at the release being installed.
cert-manager runs on the hub, and `up.sh` installs it.

## Install

`up.sh` runs the whole thing, and `GRID_REPO` points at a grid checkout at the
release being installed:

```bash
GRID_REPO=~/grid ./up.sh
```

What it runs, in order. Only what differs per cluster is set; chart defaults
cover the rest.

Two kind clusters on one podman network, MetalLB in each with a pool of its
own, and cert-manager on the hub. Those three are the only steps no chart can
express.

**The llm-d layer**, one chart per site. The sites differ by one key:

```bash
helm upgrade --install llmd-site ./charts/llmd-site \
  --kube-context kind-grid-llmd-site-a \
  --namespace grid \
  --create-namespace \
  --set site=site-a

helm upgrade --install llmd-site ./charts/llmd-site \
  --kube-context kind-grid-llmd-site-b \
  --namespace grid \
  --create-namespace \
  --set site=site-b
```

**Identity**, issued on the hub only, in its own namespace because that
namespace holds the Grid CA key. The chart runs in external mode: no enrollment
service, no invites. cert-manager generates the CA and issues one leaf per
listed site:

```bash
helm upgrade --install grid-enrollment "$GRID_REPO/charts/grid-enrollment" \
  --kube-context kind-grid-llmd-site-a \
  --namespace grid-enrollment \
  --create-namespace \
  --set mode=external \
  --set grid.membership.source=Local \
  --set external.certManager.enabled=true \
  --set external.certManager.issuer.create=true \
  --set external.certManager.ca.mode=Generate \
  --set external.sites.site-a.secretName=grid-site-a \
  --set external.sites.site-b.secretName=grid-site-b
```

Each leaf lasts 180 days and carries the names a peer verifies: the SPIFFE ID,
`<name>.grid.internal`, and under Local `<name>-signals.grid.internal` as well.
The CA key stays in `grid-ca-key` on the hub, and the chart marks it to survive
an uninstall.

## Delivering an identity to a site

The operator reads `tls.crt` and `tls.key` from `grid-site-identity` and `ca.crt`
from `grid-ca`, both in its own namespace. The issued Secret on the hub holds all
three, so delivery is reading them there and writing two Secrets on the site:

```bash
# 1. read the issued leaf and the CA from the hub
for key in tls.crt tls.key ca.crt; do
  kubectl --context "$HUB" \
    --namespace grid-enrollment \
    get secret grid-site-b \
    --output go-template="{{index .data \"$key\"}}" \
    | base64 --decode > "site-b.$key"
done

# 2. the identity, under the name the operator reads
kubectl --context "$SITE" \
  --namespace grid \
  create secret tls grid-site-identity \
  --cert=site-b.tls.crt --key=site-b.tls.key

# 3. the Grid CA beside it
kubectl --context "$SITE" \
  --namespace grid \
  create secret generic grid-ca \
  --from-file=ca.crt=site-b.ca.crt

rm site-b.tls.key
```

Confirm the identity carries the SPIFFE ID the rest of the grid authorizes on:

```bash
kubectl -n grid get secret grid-site-identity \
  -o go-template='{{index .data "tls.crt"}}' \
  | base64 -d \
  | openssl x509 -noout -subject -ext subjectAltName
```

```
subject=CN=site-b, O=site-b
X509v3 Subject Alternative Name:
    DNS:site-b.grid.internal, DNS:site-b-signals.grid.internal, URI:spiffe://grid.internal/site/site-b
```

In a fleet an ACM or OCM policy delivers these two Secrets to every selected
cluster, which is what the ai-grid hub does. Never commit a key.

**The operator** enrolls nothing. It names no signer and renders no operator
config, and it reads the identity it was given once its GridNetwork exists:

```bash
helm upgrade --install grid-operator "$GRID_REPO/charts/grid-operator" \
  --kube-context "$SITE" \
  --namespace grid \
  --set site.name=site-b \
  --set grid.membership.source=Local \
  --set grid.peerTrust=spiffe \
  --set signals.peerEndpointPort=9091 \
  --set signals.maxHandshakesPerSource=64 \
  --set signals.service.type=LoadBalancer \
  --set signals.service.externalTrafficPolicy=Cluster \
  --set signals.service.annotations."metallb\.io/loadBalancerIPs"=10.90.0.222 \
  --set signals.service.annotations."metallb\.io/allow-shared-ip"=provider-edge \
  --set gateway.serviceName=provider-gateway \
  --set gateway.port=8443
```

`grid.membership.source=Local` runs no SWIM: no SWIM Service, port, seeds or
key, and the chart refuses any value that still sets one. It also turns poll
signals on.

Peers poll this site's signals at its gateway address, under
`site-b-signals.grid.internal`, on `signals.peerEndpointPort`. So the signals
Service shares the provider gateway's load balancer address, and
`metallb.io/allow-shared-ip` is what lets MetalLB hand one address to two
Services. Sharing needs `externalTrafficPolicy` Cluster, which puts every peer
behind a node address, and the operator caps handshakes per source address, so
the cap is raised to cover the grid.

The GridNetwork reports `Enrolled` True with the message that the identity was
provisioned outside the signer, and `IdentityValid` True with the expiry. Renewal
is cert-manager on the hub renewing the Certificate, then the new Secret
delivered again, which the ACM policy does in a fleet. The operator renews
nothing itself, so `RotationOnSchedule` says so and turns `False` once the
identity is within its renewal window without a redelivery.

**The site topology** is what the operator waits for before it serves, so it
follows at once. It carries structured values, so it reads better as a file
than as `--set`:

```bash
helm upgrade --install grid-site "$GRID_REPO/charts/grid-site" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-grid-site.yaml
```

`grid-site` sets `signalTransport: poll` and `peerTrust: spiffe`, and declares
the peer. Under Local the peer's GridSite is named `site-a`, not the
`grid-llmd-site-a` SWIM discovery would have given it, and carries the peer's
gateway address. A peer whose signals are not at that address sets
`signalsEndpoint` on its entry.

**The two gateways** come last:

```bash
helm upgrade --install provider-gateway "$GRID_REPO/charts/praxis-gateway" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-provider-gateway.yaml

helm upgrade --install consumer-gateway "$GRID_REPO/charts/praxis-gateway" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-consumer-gateway.yaml
```

The provider gateway admits peers by SPIFFE ID and forwards to the local Envoy.
The consumer gateway turns on `gridServing`, which is what makes the chart
render `grid_site_route` instead of the overlay route, and lists no backends.
Every upstream comes from the dial file the operator publishes beside the
serving config: the local provider direct, and each peer through its provider
gateway at the address its GridSite declares. A backend listed in the values
under the same cluster name would be a second opinion on that dial, and the
gateway refuses a dial that changes a cluster's verified TLS identity.

**The front door**, which mints a caller key and prints it:

```bash
CTX_A=kind-grid-llmd-site-a CTX_B=kind-grid-llmd-site-b NET=grid-llmd-net \
  ./litellm/start-litellm.sh
```

## What is managed by hand under Local

Under SWIM each operator found its peers by gossip. It needed a seed address and
the shared key, and it created the peer's GridSite itself, named
`grid-llmd-<name>`, with the gateway address the peer advertised. Under Local
nothing discovers anything, so these now come from outside the grid:

- The peer GridSite records. The `peers` map in each `grid-site` values file is
  one GridSite per peer, named after the peer, with the peer's gateway address.
  A new site means adding it to every other site's values and upgrading
  `grid-site` there. A site missing from a values file is a site that cluster
  never reaches.
- The signals endpoint each peer is polled at. It is derived from the peer's
  gateway address and the operator's `signals.peerEndpointPort`, so the provider
  gateway and the signals Service share one address, or the peer entry sets
  `signalsEndpoint`.
- Nothing else carries a peer address. The consumer gateways list no backends,
  so the operator's dial file, derived from the same GridSite records, is the
  only place a peer's gateway is dialed from.
- The identity Secrets and the CA bundle. The hub issues `grid-site-<name>` per
  site, and `grid-site-identity` and `grid-ca` in each site's `grid` namespace
  are copies of it, delivered before the operator starts and delivered again on
  renewal. The operator enrolls nothing and names no signer.

In a fleet, ACM or OCM policies place the same GridSite records on every cluster
in a cluster set, or Argo CD and plain GitOps deliver the same files. Here it is
the values files and `up.sh`.

## Verify

`start-litellm.sh` mints a caller key and prints it. The master key administers
the key store; callers never use it.

```bash
curl -si http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $CALLER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-0.6B","messages":[{"role":"user","content":"hello"}]}'
```

The response headers carry the whole path:

| Header | Meaning |
|---|---|
| `x-litellm-model-id` | which consumer gateway the front door entered |
| `via` | one `1.1 praxis` when the entry site serves it, two when the request crosses to the other site's provider gateway |
| `x-grid-site` | the site Grid chose to serve it |
| `x-grid-backend` | the candidate it chose |
| `x-went-into-resp-headers` | the endpoint picker ran, so ext_proc reached llm-d |

Send a few and the entry site and serving site differ on some of them, with
two hops in `via`. That is the cross-site hop: litellm picks the entry, Grid
picks the site. litellm returns the upstream headers prefixed `llm_provider-`.

## Prefix affinity

A conversation keeps to the site already holding its prompt, or the next turn
prefills somewhere else. The consumer values set it on the chart's own knobs:

```yaml
praxisConfig:
  render:
    gridServing:
      siteRoute:
        prefixAffinity:
          enabled: true
          threshold: 0.8
          exploration: 0.02
          capacity: 16384
          ttl_secs: 600
```

`capacity` is the cache size, per backend cluster per gateway replica. See the
praxis-gateway chart values for the full set and their defaults.

**A prompt has to be long enough to have a prefix.** The gateway hashes the
prompt into 256-byte blocks and needs several before affinity applies, so a
short test prompt yields no keys and the request routes on load alone. That is
`not_applicable`, not a misconfiguration.

The gateway counts every decision, which beats inferring it from where traffic
landed:

```bash
kubectl -n grid exec deploy/consumer-gateway -- \
  wget -qO- http://127.0.0.1:9901/metrics | grep grid_route_prefix_affinity_total
```

Sending one realistic prompt repeatedly through a single gateway:

```
grid_route_prefix_affinity_total{outcome="sticky"}          18
grid_route_prefix_affinity_total{outcome="no_match"}         1
grid_route_prefix_affinity_total{outcome="not_applicable"}  73
```

The one `no_match` is the first request, before any site held the prefix; the
73 `not_applicable` are short prompts sent earlier. The traffic agrees: through
one gateway, 20 requests carrying the same long prompt all went to one site,
while 24 distinct prompts split 12 and 12.

## Reconfiguring the gateway

The gateway never needs a restart to pick up a new config. It watches the file
it was started with and swaps the running configuration in place.

**Serving data applies on its own.** The operator rewrites the serving
ConfigMap whenever the topology moves: a peer goes Active, a provider appears
or leaves, an address changes. The gateway re-reads it every five seconds. That
is how the second site's candidate arrives once its GridSite is Active, with no
rollout.

**Editing the config reloads it in place.** Change the mounted ConfigMap and
the running process swaps the new configuration once the kubelet refreshes the
file:

```
praxis::reload_diagnostics: config reload audit  chains_modified=1
praxis::reload: config reload complete  swapped=["gateway"]  skipped=[]
```

The pod's restart count stays at zero and its start time does not move. One
guard applies: a reload that would change a provider-hop backend's verified TLS
identity is refused, because a live grid route cannot silently retarget its
peer. That one asks for a restart, and says so.

**A chart upgrade does roll the pod**, because the chart stamps the rendered
config into a `checksum/config` pod annotation. Reach for it when you want the
release to stay the source of truth:

```bash
helm upgrade --install consumer-gateway "$GRID_REPO/charts/praxis-gateway" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-a-consumer-gateway.yaml \
  --set praxisConfig.render.gridServing.siteRoute.prefixAffinity.capacity=4096 \
  --set praxisConfig.render.gridServing.siteRoute.availability.shedding=true
```

Pass the values file as well as the overrides. `--reuse-values` carries the old
values forward and skips any default a newer chart added, which hides new
settings rather than applying them.

Either way, read the rendered config back rather than trusting the change
landed:

```bash
kubectl --namespace grid get configmap consumer-gateway-config \
  --output go-template='{{index .data "praxis.yaml"}}' \
  | grep --after-context=8 grid_site_route
```

The candidates and the dials are not in that file. They are in the serving
ConfigMap the operator writes, `grid-serving-grid-llmd-consumer-gateway`, as
`serving-config.json` and `dial.json`.

## Addresses

The provider gateway and the signals endpoint share one address per site, the
gateway on 8443 and signals on 9091.

| Site | Provider and signals | Consumer |
|---|---|---|
| site-a | 10.90.0.202 | 10.90.0.203 |
| site-b | 10.90.0.222 | 10.90.0.223 |

## Teardown

```bash
kind delete cluster --name grid-llmd-site-a
kind delete cluster --name grid-llmd-site-b
podman rm -f litellm-frontdoor && podman network rm grid-llmd-net
```
