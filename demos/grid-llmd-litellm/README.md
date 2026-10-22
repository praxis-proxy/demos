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

Both sites enroll: site-a runs the enrollment service, and each operator redeems
an invite and writes its own identity. Nothing hand-mints a certificate.
Signals travel by direct mTLS pull, not the gossip overlay.

## Prerequisites

kubectl, helm, kind, podman, and a grid checkout at the release being installed.

## Install

`up.sh` runs the whole thing, and `GRID_REPO` points at a grid checkout at the
release being installed:

```bash
GRID_REPO=~/grid ./up.sh
```

What it runs, in order. Only what differs per cluster is set; chart defaults
cover the rest.

Two kind clusters on one podman network, MetalLB in each with a pool of its
own, and a CoreDNS entry so both clusters resolve the hub's enrollment address.
Those four are the only steps no chart can express.

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

**Enrollment**, on the hub only, in its own namespace because that namespace
holds the Grid CA key:

```bash
helm upgrade --install grid-enrollment "$GRID_REPO/charts/grid-enrollment" \
  --kube-context kind-grid-llmd-site-a \
  --namespace grid-enrollment \
  --create-namespace \
  --set host=enroll.grid.demo \
  --set invites.site-a.network=grid-llmd \
  --set invites.site-b.network=grid-llmd \
  --set enrollment.service.type=LoadBalancer \
  --set enrollment.service.annotations."metallb\.io/loadBalancerIPs"=10.90.0.205
```

**Carrying the invite into the operator.** The enrollment chart mints one
Secret per invite, `grid-invite-<site>`, in the hub's `grid-enrollment`
namespace. The site operator looks for a Secret of that same name in its own
namespace, carrying the site label, and refuses a token labelled for another
site:

```bash
# 1. read the invite from the hub
kubectl --context "$HUB" \
  --namespace grid-enrollment \
  get secret grid-invite-site-b \
  --output go-template='{{index .data "token"}}' \
  | base64 --decode > invite-site-b.token

# 2. create it on the site, under the name the operator looks for
kubectl --context "$SITE" \
  --namespace grid \
  create secret generic grid-invite-site-b \
  --from-file=token=invite-site-b.token

# 3. label it, which is what the operator checks before redeeming
kubectl --context "$SITE" \
  --namespace grid \
  label secret grid-invite-site-b \
  grid.praxis.fast/site=site-b

rm invite-site-b.token
```

Two more Secrets travel the same way: `grid-ca-bundle` from `grid-enrollment`,
which is what the site checks the enrollment service against, and the shared
`grid-swim-key`. A fleet delivers all three over one protected channel, with
ACM or External Secrets. Never commit an invite or the SWIM key.

**The operator redeems it** on first start and writes its own identity. The
enrollment names below are chart defaults, spelled out so the flow is visible:

```bash
helm upgrade --install grid-operator "$GRID_REPO/charts/grid-operator" \
  --kube-context "$SITE" \
  --namespace grid \
  --set enrollment.enabled=true \
  --set enrollment.url=https://enroll.grid.demo:8443 \
  --set enrollment.siteName=site-b \
  --set enrollment.tokenSecretRef.name=grid-invite-site-b \
  --set enrollment.caBundle.secret=grid-ca-bundle \
  --set enrollment.identitySecretName=grid-site-identity \
  --set enrollment.caSecretName=grid-ca \
  --set swim.siteName=site-b \
  --set swim.seeds=10.90.0.201:7946 \
  --set swim.service.type=LoadBalancer \
  --set swim.service.annotations."metallb\.io/loadBalancerIPs"=10.90.0.221 \
  --set signals.enabled=true \
  --set signals.service.annotations."metallb\.io/loadBalancerIPs"=10.90.0.224 \
  --set gateway.serviceName=provider-gateway \
  --set gateway.port=8443
```

The invite is one-time. If `grid-site-identity` is deleted the operator retries
a spent token, so do not let Argo prune it.

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
    DNS:site-b.grid.internal, URI:spiffe://grid.internal/site/site-b
```

Wait for `grid-site-identity` to appear, then the site topology and the two
gateways. These carry structured values, so they read better as files than as
`--set`:

```bash
helm upgrade --install grid-site "$GRID_REPO/charts/grid-site" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-grid-site.yaml

helm upgrade --install provider-gateway "$GRID_REPO/charts/praxis-gateway" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-provider-gateway.yaml

helm upgrade --install consumer-gateway "$GRID_REPO/charts/praxis-gateway" \
  --kube-context "$SITE" \
  --namespace grid \
  --values values/site-b-consumer-gateway.yaml
```

`grid-site` sets `signalTransport: poll` and `peerTrust: spiffe`, and declares
the peer. The provider gateway admits peers by SPIFFE ID and forwards to the
local Envoy. The consumer gateway turns on `gridServing`, which is what makes
the chart render `grid_site_route` instead of the overlay route.

**The front door**, which mints a caller key and prints it:

```bash
CTX_A=kind-grid-llmd-site-a CTX_B=kind-grid-llmd-site-b NET=grid-llmd-net \
  ./litellm/start-litellm.sh
```

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
| `via: 1.1 praxis, 1.1 praxis` | two Grid hops, consumer then provider |
| `x-grid-site` | the site Grid chose to serve it |
| `x-grid-backend` | the candidate it chose |
| `x-went-into-resp-headers` | the endpoint picker ran, so ext_proc reached llm-d |

Send a few and the entry site and serving site differ on some of them. That is
the cross-site hop: litellm picks the entry, Grid picks the site.

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
is how the second site's candidate arrives after enrollment, with no rollout.

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

## Addresses

| Site | SWIM | Signals | Provider | Consumer | Enrollment |
|---|---|---|---|---|---|
| site-a | 10.90.0.201 | 10.90.0.204 | 10.90.0.202 | 10.90.0.203 | 10.90.0.205 |
| site-b | 10.90.0.221 | 10.90.0.224 | 10.90.0.222 | 10.90.0.223 | n/a |

## Teardown

```bash
kind delete cluster --name grid-llmd-site-a
kind delete cluster --name grid-llmd-site-b
podman rm -f litellm-frontdoor && podman network rm grid-llmd-net
```
