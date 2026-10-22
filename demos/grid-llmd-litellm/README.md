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

```bash
GRID_REPO=~/grid ./up.sh
CTX_A=kind-grid-llmd-site-a CTX_B=kind-grid-llmd-site-b NET=grid-llmd-net \
  ./litellm/start-litellm.sh
```

`up.sh` runs, in order:

1. Creates a podman network on 10.90.0.0/24 and two kind clusters on it.
2. Installs MetalLB in each, one pool per site so the two cannot hand out the same address.
3. Points both clusters' CoreDNS at the hub's enrollment address.
4. Installs the llm-d layer as one chart per site: InferencePool, two simulators, the endpoint picker, and Envoy.
5. Installs grid-enrollment on the hub, which creates the Grid CA and one invite per site.
6. Copies the CA bundle, each site's invite, and the SWIM key, then installs grid-operator per site and waits for each to enroll.
7. Installs grid-site, the provider gateway, and the consumer gateway per site.

Every component is a chart invoked with one values file. The Grid charts come
from GRID_REPO; llmd-site ships with the demo:

```
charts/llmd-site         --set site=<site>
charts/grid-enrollment   values/hub-grid-enrollment.yaml
charts/grid-operator     values/<site>-grid-operator.yaml
charts/grid-site         values/<site>-grid-site.yaml
charts/praxis-gateway    values/<site>-provider-gateway.yaml
charts/praxis-gateway    values/<site>-consumer-gateway.yaml
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

Repeat one prompt and it sticks to a single site; distinct prompts spread.

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
