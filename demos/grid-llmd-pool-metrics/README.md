# Grid LLM-d Pool Metrics Demo

Proves that metrics from vllm-vcr drive EPP aggregation, Grid scoring, overlay
publication, and Praxis routing decisions across two Kind clusters. Each
cluster runs two vllm-vcr inference backends: a vllm-rs HTTP frontend paired
with the vllm-vcr mock engine-core. The frontend exposes vLLM-compatible
Prometheus metrics, while every other component -- llm-d EPP, Grid operator,
overlay delivery, Praxis routing -- runs its production code path.

No GPU or model weights are required. The vllm-rs frontend downloads only the
tokenizer from Hugging Face at startup.

## Video Demonstration

https://github.com/user-attachments/assets/a3bffc75-3ca8-4e8c-99f4-900e7c44e0bc

## Architecture

```text
                          Grid / Praxis
                               |
                     +---------+---------+
                     |                   |
              consumer-gateway    consumer-gateway
              (overlay routing)   (overlay routing)
                     |                   |
              provider-gateway    provider-gateway
              (mTLS + creds)      (mTLS + creds)
                     |                   |
          +----------+------+   +--------+--------+
          |    pool-a       |   |    pool-b        |
          |                 |   |                  |
          | vcr-1 vcr-2     |   | vcr-1 vcr-2      |
          |  (vllm-vcr)     |   |  (vllm-vcr)      |
          |    |     |      |   |    |     |       |
          |    +--+--+      |   |    +--+--+       |
          |       |         |   |       |          |
          |   llm-d EPP     |   |   llm-d EPP      |
          |   :9090/metrics |   |   :9090/metrics  |
          |       |         |   |       |          |
          |  Grid Operator  |   |  Grid Operator   |
          +--------+--------+   +--------+---------+
                   |    SWIM mesh (UDP)    |
                   +--------+--------------+

pressure-generator (pool-a only, scaled 0 at rest)
       |
       +---> consumer-gateway.grid-system:8080
             /v1/chat/completions
             (routed through full Grid path)
```

Each [vllm-vcr](https://github.com/neuralmagic/vllm-vcr/blob/main/README.md) pod
runs two processes via `entrypoint.sh`:
- **vllm-rs**: the real vLLM Rust HTTP frontend (serves /health, /v1/models,
  /v1/chat/completions, /metrics on port 8000)
- **vllm-vcr play**: mock engine-core backend (connects via ZMQ handshake,
  generates random tokens with configurable latency)

## What It Proves

This demo makes the complete metrics-driven routing path visible:

- vllm-rs is the HTTP frontend for VCR and exposes vLLM-compatible Prometheus
  metrics
- llm-d EPP aggregates per-backend metrics into pool-level summaries
- Grid operator scrapes EPP and scores backends with the production scoring
  engine
- Gateway-routed load visibly shifts request attribution from pool-a to pool-b
  as pressure builds, not just rank changes
- The live metrics table shows queue depth, KV-cache, scores, ranks, per-pool
  request counts, and last-route attribution through the full lifecycle
- Pool A recovers after load is removed: its queue drains, its rank returns to
  zero, and traffic attribution returns to pool-a
- A content-addressed overlay is published and hot-reloaded without pod
  restart
- The scorecard shows raw metrics, weighted scores, and ranks from the same
  overlay revision
- Optional metrics TLS lifecycle (9 stages): baseline mTLS, handshake
  rejection, missing client identity, wrong CA, valid restore, stale-cache TTL
  expiry and recovery, client cert rotation, server cert rotation with nginx
  restart, and end-to-end routing verification after the full TLS cycle

## Metrics Transport

llm-d EPP normally exposes Prometheus metrics over HTTP on port `9090`. In the
default demo mode, Grid scrapes that endpoint directly.

The optional `--metrics-mtls` mode adds nginx in front of the EPP metrics
endpoint. nginx requires a Grid operator client certificate, terminates TLS on
port `9443`, and forwards the scrape to EPP over local HTTP.

```text
Default:  Grid operator ---- HTTP ----> llm-d EPP :9090/metrics

mTLS:     Grid operator -- HTTPS/mTLS -> nginx :9443
                                            |
                                            +-- HTTP -> llm-d EPP :9090/metrics
```

## Scoring and Routing Policy

This demo ships two Forge config flavors that share the same
resources/configs assets and differ only in which Grid scoring strategy the
GridNetwork selects, both with routingPolicy: scoreFirst:

| Flavor | Forge config | GridNetwork setting |
|---|---|---|
| queueDepth (default) | `forge.yaml` | `scoringPolicy: { strategy: queueDepth }` |
| kvCachePressure | `forge-kv-cache.yaml` | `scoringPolicy: { strategy: kvCachePressure }` |

Run either with `./run.sh`; pass `--kv-cache` to select the second flavor
(see [Quick Start](#quick-start) / [Full Mode](#full-mode) below).

Grid normalizes the EPP queue depth using queueCapacity: 4 and computes the
dynamic provider score for the queueDepth flavor as:

    score = 1 - normalized_queue_depth

The provider with the lower queue therefore receives the better dynamic
score. For the kvCachePressure flavor, the provider with the most available
KV-cache capacity receives the better score instead. Both signals are always
collected and shown in the live table regardless of which flavor is running,
but Grid selects one provider-level metric strategy at a time so the routing
decision remains explainable.

Available strategies are:

| Strategy | Behavior |
|---|---|
| noMetrics | Default when scoringPolicy is omitted; uses health, admission, locality, freshness, and other routing rules without dynamic metric scoring. |
| queueDepth | Prefers the provider with the lowest normalized queue depth. |
| kvCachePressure | Prefers the provider with the most available KV-cache capacity. |

geographyFirst is the default routing policy and preserves locality ahead of
score. This demo uses scoreFirst so a sufficiently better score can move
traffic to the remote pool.

## Controlled Pressure

The demo generates real HTTP load through the **consumer Grid gateway**.
Traffic flows through the full routing chain: consumer gateway, intelligent
routing overlay, provider gateway (mTLS), and finally to VCR backends. A
pressure-generator Deployment
in pool-a starts scaled to zero and is controlled by the xtask orchestration:

1. **Baseline**: Both pools idle, pool-a preferred (rank 0). Probe requests
   through the gateway confirm pool-a attribution.
2. **Pressure**: Xtask scales pressure-generator to 3 replicas, each sending
   4 concurrent `/v1/chat/completions` requests through the consumer gateway.
   Initially all requests route to pool-a (rank 0).
3. **Failover**: Pool-a queue depth and KV-cache utilization rise, EPP reports
   pressure, scoring engine flips preference to pool-b. Subsequent requests
   are routed to pool-b, visible in both the attribution headers and the live
   metrics table.
4. **Recovery**: Xtask scales pressure-generator to 0. Both pools drain, pool-a
   regains rank 0. Probe requests confirm pool-a attribution restored.

Each pressure-generator pod tracks request attribution via the
`X-Grid-LlmD-Provider-Gateway` response header and reports per-pool counts.
The xtask reads these counts and displays a live metrics table:

```text
TIME   PHASE      A_QUEUE  A_KV A_SCORE A_RANK  B_QUEUE  B_KV B_SCORE B_RANK  A_REQ B_REQ LAST_ROUTE
00:10  BASELINE       0.0  .00   11.00      0      0.0  .00    9.50      1       0     0          -
00:25  PRESSURE       3.2  .45    8.10      0      0.0  .00    9.50      1      18     0     pool-a
00:40  FAILOVER       4.0  .81    5.48      1      1.0  .12    9.26      0      31    12     pool-b
01:05  RECOVERY       0.5  .08   10.84      0      0.0  .00    9.50      1      42    19     pool-a
```

VCR pods are configured with small scheduler limits (`MOCK_MAX_NUM_SEQS=4`,
`MOCK_KV_CACHE_SIZE=64`) and moderate latency (`MOCK_TTFT_MS=50`,
`MOCK_ITL_MS=20`) so that modest gateway-routed load creates observable
pressure.

## Prerequisites

- A local [praxis-proxy/grid](https://github.com/praxis-proxy/grid) checkout (or set `GRID_REPO`)
- Docker or Podman
- kind
- Rust stable 1.96+
- Network access for Hugging Face tokenizer download (first run)
- Approximately 8 GB RAM for two Kind clusters (vllm-vcr pods require more
  memory than the earlier backend)

## Registry Images

These are the defaults used by `run.sh`; no preloaded local image is required.

```bash
export GRID_XTASK_GATEWAY_IMAGE=ghcr.io/praxis-proxy/grid-ai-rollup:v0.1.3
export GRID_XTASK_OPERATOR_IMAGE=ghcr.io/praxis-proxy/grid-operator:v0.1.3
export GRID_XTASK_EPP_IMAGE=ghcr.io/llm-d/llm-d-inference-scheduler:v0.8.0
export GRID_XTASK_VCR_IMAGE=ghcr.io/neuralmagic/vllm-vcr:vllm0.23
export GRID_XTASK_OVERLAY_SYNC_IMAGE=ghcr.io/praxis-proxy/grid-overlay-sync:v0.1.3
export GRID_XTASK_IMAGE_PULL_POLICY=IfNotPresent
```

For AI development, set `GRID_XTASK_GATEWAY_IMAGE` to a local image built from
a `praxis-proxy/ai` revision containing
[`provider_route`](https://github.com/praxis-proxy/ai/pull/386), then set
`GRID_XTASK_IMAGE_PULL_POLICY=Never`.

Only the optional mTLS mode also needs nginx:

```bash
export GRID_XTASK_NGINX_IMAGE=docker.io/library/nginx:1.27.4-alpine
```

The complete image set is:

| Image | Env var | Purpose |
|-------|---------|---------|
| `llm-d-epp` | `GRID_XTASK_EPP_IMAGE` | llm-d Endpoint Picker / metrics aggregator |
| `vllm-vcr` | `GRID_XTASK_VCR_IMAGE` | vllm-rs frontend + vllm-vcr mock engine-core |
| `nginx` | `GRID_XTASK_NGINX_IMAGE` | Optional mTLS proxy for EPP metrics |
| `grid-overlay-sync` | `GRID_XTASK_OVERLAY_SYNC_IMAGE` | Overlay ConfigMap delivery sidecar |

## Local Image Development

To build the vllm-vcr image locally from the checked-out repository:

```bash
cd vllm-vcr
docker build -t ghcr.io/neuralmagic/vllm-vcr:vllm0.23 .
```

For Kind clusters, load the image after building:

```bash
export GRID_XTASK_VCR_IMAGE=ghcr.io/neuralmagic/vllm-vcr:vllm0.23
```

The xtask loads images into Kind nodes automatically. Set
`imagePullPolicy: IfNotPresent` (the default) so Kind uses the loaded image
instead of pulling from the registry.

The vllm-rs frontend downloads the Qwen/Qwen3-0.6B tokenizer from Hugging Face
on first startup. In Kind, pods have internet access via Docker networking. If
running in an air-gapped environment, pre-populate `HF_HOME` (default `/tmp/hf`
inside the container) with the tokenizer files.

## Quick Start

```bash
./run.sh --quick --teardown
```

This scrapes EPP directly over HTTP and does not deploy nginx or metrics TLS
certificates.

To validate an mTLS-protected metrics endpoint:

```bash
./run.sh --quick --metrics-mtls --teardown
```

## Full Mode

```bash
./run.sh --full --teardown
```

Full mode adds the pressure-flip and recovery proofs.

To run the same proofs against the kvCachePressure flavor instead:

```bash
./run.sh --full --kv-cache --teardown
```

`--kv-cache` selects `forge-kv-cache.yaml` in place of `forge.yaml`; every
other flag (`--quick`, `--metrics-mtls`, `--teardown`, `--keep-on-failure`)
works the same with either flavor.

## Teardown and Keep-on-Failure

`--teardown` deletes both Kind clusters after the run, including on failure.
Add `--keep-on-failure` to retain clusters when a proof fails:

```bash
./run.sh --quick --teardown --keep-on-failure
```

## Evidence

Each run writes evidence to the evidence directory (default: `evidence/`).
See [e2e-demo-output.txt](e2e-demo-output.txt) for example output from a
successful run.

## Troubleshooting

**VCR pods stuck in init / not ready**: The vllm-rs frontend downloads the
tokenizer from Hugging Face on first start. Check pod logs for download
progress. The startup probe allows up to 600 seconds.

**EPP shows no metrics**: Verify that the InferencePool selector (`app:
vllm-vcr`) matches the VCR pod labels. Check that VCR pods respond to
`/metrics` by exec-ing into a pod and running `curl localhost:8000/metrics`.

**Pressure does not cause flip**: Verify the pressure-generator pods are
running (`kubectl get pods -l app=pressure-generator -n grid-system`). Check
that the consumer gateway is reachable from the pressure pods. Verify VCR pod
logs show incoming requests. Ensure `MOCK_MAX_NUM_SEQS` is small enough
(default 4) that requests queue quickly. Check the live table LAST_ROUTE
column to see if attribution is shifting.

**Queue does not drain after pressure stops**: VCR pods process queued requests
to completion. Recovery takes longer with high `max_tokens` in the pressure
generator requests or with `MOCK_TIME_FACTOR_UNDER_LOAD > 1.0`.

## Known Limitations

- No real GPU inference; vllm-vcr generates random tokens, so response content
  is meaningless.
- No P99 latency or prefix-cache derivation; those signals are not used by
  either the queueDepth or kvCachePressure strategy.
- Two-pool topology; each cluster's own provider scores with full locality
  (1.0) while the remote peer scores at 0.5.
- No cost signal; defaults to 0.5.
- No hysteresis or minimum switch margin; a score difference triggers a rank
  change.
- Missing queue telemetry scores neutrally, which can cause an unobservable
  provider to outrank one with known high pressure.

## Implementation Documentation

See the [Grid repository](https://github.com/praxis-proxy/grid) for full
architecture, scoring model, and implementation details. See the
[vllm-vcr README](https://github.com/neuralmagic/vllm-vcr/blob/main/README.md)
for the VCR architecture, entrypoint configuration, and deployment examples.
