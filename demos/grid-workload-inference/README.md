# Grid Workload Inference Demo

Proves workload-originated inference through Grid provider selection without
public ingress. Workloads submit requests from inside consumer clusters through
their local Praxis consumer gateway; no GTM emulator or external endpoint is
involved. Uses the GLB topology with `--no-ingress` to produce a four-cluster
resolved config.

## Topology

```text
+----------------------------+  +----------------------------+
| east consumer cluster      |  | west consumer cluster      |
|                            |  |                            |
| workload Job               |  | workload Job               |
|      |                     |  |      |                     |
|      v                     |  |      v                     |
| Praxis consumer gateway    |  | Praxis consumer gateway    |
| Grid operator and overlay  |  | Grid operator and overlay  |
+-------------+--------------+  +--------------+-------------+
              |                                |
              +--------- Grid selection -------+
                               |
                    +----------+----------+
                    |                     |
                    v                     v
+----------------------------+  +----------------------------+
| east provider cluster      |  | west provider cluster      |
| Praxis provider gateway    |  | Praxis provider gateway    |
| private inference endpoint |  | private inference endpoint |
| Grid operator              |  | Grid operator              |
+----------------------------+  +----------------------------+

4 Kind clusters (GLB topology minus GTM), model=Qwen/Qwen3-0.6B
```

## What It Proves

- Four clusters created and healthy with SWIM membership across all sites
- Grid operators converge overlay for each consumer site
- Three provider candidates discovered (two at east, one at west)
- East and west workload Jobs succeed via in-cluster consumer gateway
- Provider mTLS, peer authorization, and credential replacement enforced
- NetworkPolicy isolates backends
- VCR backend readiness and provider health availability are enforced
- Explicit provider withdrawal causes health-based failover and recovery
- Response attribution identifies the full routing path
- Clean teardown of four clusters

## Scoring and Routing Policy

This demo uses the GLB topology's default `geographyFirst` routing policy and
does not configure a dynamic provider metric strategy. The default `noMetrics`
strategy therefore applies: health, admission, locality, freshness, and
provider availability determine routing. The failover proof intentionally
withdraws a provider's availability and verifies that traffic moves to a
healthy provider, then returns after recovery.

Grid also supports `scoreFirst` with `queueDepth` or `kvCachePressure` for
deployments that expose comparable telemetry. Those metric-driven strategies
are demonstrated by the [llm-d pool metrics demo](../grid-llmd-pool-metrics/),
not by this cluster-local workload demo.

## Prerequisites

- A local [praxis-proxy/grid](https://github.com/praxis-proxy/grid) checkout (or set `GRID_REPO`)
- Docker
- kind, kubectl, curl, OpenSSL on `PATH`
- Rust stable 1.96+
- Approximately 16 GB RAM for four Kind clusters

## Registry Images

```bash
export GRID_XTASK_GATEWAY_IMAGE=ghcr.io/praxis-proxy/grid-ai-rollup:v0.1.3
export GRID_XTASK_OPERATOR_IMAGE=ghcr.io/praxis-proxy/grid-operator:v0.1.3
export GRID_XTASK_VCR_IMAGE=ghcr.io/neuralmagic/vllm-vcr:vllm0.23
export GRID_XTASK_IMAGE_PULL_POLICY=IfNotPresent
```

The provider clusters run
[vllm-vcr](https://github.com/neuralmagic/vllm-vcr/blob/main/README.md) with
the `Qwen/Qwen3-0.6B` model identifier. Its vllm-rs HTTP frontend serves the
OpenAI-compatible endpoint while the VCR engine-core provides simulated
inference behavior for the demo.

## Quick Start

```bash
./run.sh --quick --teardown
```

## Full Mode

```bash
./run.sh --full --teardown
```

Full mode adds local provider preference, remote provider fallback after drain,
and extended lifecycle proofs.

## Teardown and Keep-on-Failure

`--teardown` deletes all Kind clusters after the run, including on failure.
Add `--keep-on-failure` to retain clusters when a proof fails:

```bash
./run.sh --quick --teardown --keep-on-failure
```

## Evidence

Each run writes evidence to `.forge/evidence/`. See
[e2e-demo-output.txt](e2e-demo-output.txt) for checked-in example output.

## Known Limitations

- No external ingress or public endpoint; add a traffic manager separately.
- Kind networking does not represent production latency or failure modes.
- VCR backends provide simulated inference responses; this demo evaluates Grid
  health and availability failover, not production model quality or throughput.
- The forge.yaml is sourced from `grid-glb-demo/`; this demo has no
  independent forge config.

## Implementation Documentation

See the [Grid repository](https://github.com/praxis-proxy/grid) for full
architecture, design documentation, and implementation details.
