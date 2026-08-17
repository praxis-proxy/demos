# Grid GLB Demo

One stable HTTPS inference endpoint backed by two active Praxis edge gateways,
two private provider gateways, and a local GTM emulator that selects a healthy
edge. The provider clusters run CPU-only `vllm-vcr` backends serving
`Qwen/Qwen3-0.6B`; the east provider cluster hosts two independent VCR
providers, proving that Grid does not assume one provider per cluster.

## Video Demonstration

https://github.com/user-attachments/assets/684ff927-5bb0-4fc8-afa1-bdac71bf41df

## Topology

```text
                    Inference client
                          |
                          v
               +--------------------+
               | GTM emulator       |
               | (grid-glb-gtm-     |
               |  emulator)         |
               +---------+----------+
                         |
                +--------+--------+
                |                 |
                v                 v
      +----------------+  +----------------+
      | east-edge      |  | west-edge      |
      | intelligent_   |  | intelligent_   |
      | route + overlay|  | route + overlay|
      +-------+--------+  +-------+--------+
              |                    |
       +------+------+     +------+------+
       |             |     |             |
       v             v     v             v
+-----------+  +-----------+  +-----------+
| east-     |  | east-     |  | west-     |
| provider  |  | provider  |  | provider  |
| (primary) |  | (second.) |  |           |
+-----------+  +-----------+  +-----------+

5 Kind clusters, 4-member SWIM mesh (GTM excluded)
```

## What It Proves

- Active/active global routing with independent Grid provider selection
- Local GTM emulator selects a healthy edge (not Route 53 or Internet-scale GSLB)
- Two independent providers at the east site with distinct stable IDs
- Secure provider boundary: mTLS, peer authorization, credential replacement
- Edge and provider session affinity under separate keys
- Provider withdrawal, recovery, and failback through the existing GLB scenario
- Live overlay hot reload without pod restart
- Edge withdrawal, recovery, and failback behind one HTTPS name

## Scoring and Routing Policy

This demo intentionally uses Grid's default provider scoring behavior:

    scoringPolicy is omitted, which defaults to noMetrics.
    routingPolicy is omitted, which defaults to geographyFirst.

noMetrics does not disable routing policy. Health, admission, model
compatibility, locality, freshness, session affinity, and provider availability
still determine which candidates are eligible and how they are ordered.
Because this GLB topology does not collect VCR/EPP pressure metrics, it does
not use queueDepth or kvCachePressure to make routing decisions.

Grid also supports queueDepth and kvCachePressure for deployments with
comparable provider telemetry. scoreFirst can allow a better metric score to
outrank locality; geographyFirst keeps locality ahead of dynamic score and is
the default used here.

## Prerequisites

- A local [praxis-proxy/grid](https://github.com/praxis-proxy/grid) checkout (or set `GRID_REPO`)
- Docker
- kind, kubectl, curl, OpenSSL on `PATH`
- Rust stable 1.96+ and the repository-pinned nightly toolchain
- Capacity for five single-node Kind clusters

## Registry Images

These are the defaults used by `run.sh`; no preloaded local image is required.

```bash
export GRID_XTASK_GATEWAY_IMAGE=ghcr.io/praxis-proxy/grid-ai-rollup:v0.1.3
export GRID_XTASK_OPERATOR_IMAGE=ghcr.io/praxis-proxy/grid-operator:v0.1.3
export GRID_XTASK_VCR_IMAGE=ghcr.io/neuralmagic/vllm-vcr:vllm0.23
export GRID_XTASK_IMAGE_PULL_POLICY=IfNotPresent
```

For AI development, override the gateway with a locally built image and use
`GRID_XTASK_IMAGE_PULL_POLICY=Never`. The selected `praxis-proxy/ai` revision
must contain [`provider_route`](https://github.com/praxis-proxy/ai/pull/386):

```bash
export GRID_XTASK_GATEWAY_IMAGE=praxis-ai:dev
export GRID_XTASK_OPERATOR_IMAGE=grid-operator:dev
export GRID_XTASK_IMAGE_PULL_POLICY=Never
```

## Quick Start

```bash
./run.sh --quick --teardown
```

## Full Mode

```bash
./run.sh --full --teardown
```

Full mode adds repeated affinity, explicit provider availability withdrawal and
recovery, edge withdrawal/recovery, sequential Grid operator restarts, and a
configured request soak. The provider transition is an availability/failover
exercise, not an EPP pressure-scoring exercise.

## Teardown and Keep-on-Failure

`--teardown` deletes all Kind clusters after the run, including on failure.
Add `--keep-on-failure` to retain clusters when a proof fails:

```bash
./run.sh --quick --teardown --keep-on-failure
```

## Evidence

Each run writes machine-readable evidence to a timestamped directory under
`.forge/evidence/` (or the path given by `--evidence-dir`).

See [e2e-demo-output.txt](e2e-demo-output.txt) for checked-in example output
from a quick cold run.

## Known Limitations

- The GTM emulator is a local stand-in; it does not reproduce Internet routing,
  DNS propagation, Anycast, geographic steering, or DDoS protection.
- Kind networking does not represent production latency or failure modes.
- `vllm-vcr` provides CPU-only OpenAI-compatible responses without model weights;
  it is a response/latency simulator, not model-quality inference.
- This GLB mode does not use VCR/EPP metrics for Grid scoring. Pressure and
  provider-metrics demonstrations belong to the llm-d pool-metrics demo.
- The emulator-to-edge hop is plaintext HTTP inside the isolated demo network.

## Implementation Documentation

The VCR backend is documented at
[neuralmagic/vllm-vcr](https://github.com/neuralmagic/vllm-vcr/blob/main/README.md).
See the [Grid repository](https://github.com/praxis-proxy/grid) for full
architecture, design documentation, and implementation details.
