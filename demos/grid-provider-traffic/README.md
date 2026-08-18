# Grid provider traffic demo

This demo shows one consumer gateway process distributing new requests across
three distinct provider gateways. Each provider gateway forwards to its own VCR
backend, so the response identifies the selected provider and the request path
can be checked in the tracing UI.

```text
                         Client traffic
                              |
                    Consumer / Edge Gateway
                              |
                       intelligent_route
                              |
          +-------------------+-------------------+
          |                   |                   |
   Provider Gateway A  Provider Gateway B  Provider Gateway C
          |                   |                   |
     Provider stack A    Provider stack B    Provider stack C
          |                   |                   |
       VCR backend A       VCR backend B       VCR backend C
```

All three providers are equivalent group-0 candidates. This focused demo does
not include a fallback provider, a second consumer, GLB, or DNS routing.

The demo uses one consumer gateway to keep the proof easy to follow. Grid also
supports multiple consumer or edge gateways for scale-out. Each consumer keeps
its own in-memory selection state; the counters are not globally coordinated.
The provider gateways are independent serving destinations. Grid selects the
provider gateway, while each provider's own serving stack remains responsible
for selecting an endpoint, replica, or backend behind that gateway.

## Routing policy

```yaml
routingPolicy: scoreFirst
scoringPolicy:
  strategy: noMetrics
selectionPolicy:
  mode: roundRobin
```

These settings are intentionally separate:

- `routingPolicy` determines how Grid orders candidates and creates priority
  groups.
- `scoringPolicy: noMetrics` means no EPP, Prometheus, queue, or KV signal is
  used to choose a preferred provider.
- `selectionPolicy.mode: roundRobin` tells the consumer gateway to rotate new,
  unbound requests through the viable candidates in the best group.
- Session affinity is checked first, so a request with an existing valid
  session binding stays with its provider instead of advancing the rotation.
- Lower groups, when published by a future admission scenario, are failover
  groups rather than another pool to mix into normal traffic.

No EPP, Prometheus, inference metrics, GTM, DNS balancing, or weighted routing
is part of this proof. VCR supplies deterministic backend responses; it is not
the load-balancing component.

## What the proof checks

The cold quick run creates three provider Kind clusters, establishes SWIM
discovery and trust, deploys one consumer gateway in the provider-a cluster,
waits for the global overlay, and then sends 60 serial requests through that
single entrypoint. It requires:

- one ready consumer replica and three ready provider replicas;
- `selection_policy.mode: roundRobin` in the consumed overlay;
- three fresh `NewAndExisting` candidates in group 0;
- the operator revision, overlay revision, and Praxis serving revision to
  agree before traffic starts;
- exactly 20 requests per provider;
- one repeating three-provider cycle from the first measured request;
- no ConfigMap revision change, overlay reload, or gateway restart during the
  measured window.

The measured request path is local to the consumer gateway after the overlay
has been loaded. It does not call Grid, Kubernetes, EPP, or a scoring service
for each request.

## Run

The demo uses the published development images below, so the container images
do not need to be built locally. The tags are immutable research artifacts,
not an official Grid or Praxis release.

```bash
source demos/grid-provider-traffic/configs/images.env
```

These are immutable development image tags. Verify each tag resolves to the
expected digest before running:

| Component | Image | Expected digest |
|---|---|---|
| Praxis gateway | `ghcr.io/nerdalert/praxis-ai:grid-provider-selection-otel-20260814-536534aba5c1` | `sha256:7d51ccf7324d2a7627a4f235991be8cd94a7546896bae53ae25fad837aa51721` |
| Grid operator | `ghcr.io/nerdalert/grid-operator:provider-selection-20260814-d965540dad8d` | `sha256:a3019d693309c8c5ad3568e9843012944d0bc370bbd00c587b8c286e92c29d63` |
| Overlay sync | `ghcr.io/nerdalert/grid-overlay-sync:provider-selection-20260814-d965540dad8d` | `sha256:a267c3552709aac9aa73b368b14df1c2d69d3e16d92a31b19bdeea9767521b94` |
| VCR backend | `ghcr.io/neuralmagic/vllm-vcr:vllm0.23` | fixed upstream demo image reference |

For example:

```bash
docker buildx imagetools inspect \
  ghcr.io/nerdalert/praxis-ai:grid-provider-selection-otel-20260814-536534aba5c1
docker buildx imagetools inspect \
  ghcr.io/nerdalert/grid-operator:provider-selection-20260814-d965540dad8d
docker buildx imagetools inspect \
  ghcr.io/nerdalert/grid-overlay-sync:provider-selection-20260814-d965540dad8d
```

Until the provider-traffic xtask entrypoint is merged into Grid main, use the
public feature branch that contains it:

```bash
git clone --branch feat/provider-selection-groups \
  https://github.com/nerdalert/grid.git grid-provider-selection-grid
export GRID_REPO="$PWD/grid-provider-selection-grid"
```

From a demos checkout and with `GRID_REPO` set, run:

```bash
./demos/grid-provider-traffic/run.sh --quick --teardown
```

The command creates three Kind clusters, deploys one consumer gateway and
three provider gateways, waits for overlay convergence, sends the measured
60-request proof, and removes only the clusters created by this demo.

For development with local Grid and AI workspaces, set the documented image
overrides and use `GRID_XTASK_IMAGE_PULL_POLICY=Never` so Kind receives the
fresh local images. The run records machine-readable evidence under the demo's
ignored `evidence/` directory.

## Observe with Praxis Tracing

The [Praxis Tracing repository](https://github.com/nerdalert/praxis-tracing)
supports this source as **Provider traffic**. Start
Jaeger and the UI, set `TRACING_UI_PROFILE=provider`, and configure
`PROVIDER_TRAFFIC_GATEWAY_URL` to the consumer gateway address. The dashboard's
Generate Requests action sends real requests through that gateway and shows:

- each HTTP response and selected provider;
- the observed consumer-to-provider path;
- provider attribution counts for the current trace window;
- exact trace evidence when the OTel collector receives the spans;
- the request detail flow from client to consumer gateway, provider gateway,
  and VCR backend.

The OTel collector endpoint must be reachable from the gateway pods. In a
local Kind setup, use the collector service address or the Docker host gateway
appropriate to that environment; do not silently treat missing traces as
successful tracing.

## Published cold-start prerequisites

The supported clean-machine path requires Git, Docker, Kind, kubectl, Helm,
Rust/Cargo, and enough capacity for three Kind clusters and their workloads
(at least 8 CPUs, 16 GB RAM, and 30 GB free disk is a practical starting
point). The host must be able to pull public packages from GHCR.

The wrapper builds the Forge and xtask binaries locally, but it does not build
the gateway, operator, overlay-sync, or tracing UI container images. The
published image configuration is in
`demos/grid-provider-traffic/configs/images.env`.

The tracing UI is a separate container. Start it after the demo has exposed
Jaeger and the consumer gateway:

```bash
docker run --rm --name praxis-tracing \
  -p 3001:8080 \
  -e TRACING_UI_PROFILE=provider \
  -e JAEGER_URL=http://host.docker.internal:16686 \
  -e PROVIDER_TRAFFIC_GATEWAY_URL=http://host.docker.internal:<consumer-port> \
  "$TRACING_UI_IMAGE"
```

Open `http://localhost:3001`. The consumer port is the endpoint printed by
the demo or established with its documented port-forward. The UI's Generate
Requests action sends traffic through that consumer gateway; it does not
replace the demo's measured 60-request proof.

For a recording, show the topology first, then the distribution summary, a
request detail, and the **Open raw trace** link to Jaeger. A replay may be
unavailable when request bodies are intentionally not retained; do not imply
that arbitrary production prompts or credentials can be replayed.

For a fully public cold start, the demo checkout must contain the provider-
traffic xtask entrypoint and the overlay-sync image propagation changes. Do
not use this command against an older demos/Grid checkout that lacks those
changes.

## Scope

This is provider-gateway traffic distribution. It does not prove provider-local
replica balancing inside VCR, metric-derived scoring, weighted traffic, GLB,
GTM, DNS selection, or cross-region latency optimization.
