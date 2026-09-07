# Anthropic Messages API Demo

Demonstrates routing Anthropic `/v1/messages` requests through Praxis
to different backends with optional format transformation.

## Files

| File | Description |
|------|-------------|
| `goals.md` | One-page summary of what this demo covers |
| `demo.md` | Step-by-step walkthrough with curl commands |
| `passthrough.yaml.tmpl` | Config template: classify, validate JSON envelopes, route by model to Anthropic API or vLLM |
| `transform.yaml.tmpl` | Config template: transform Anthropic Messages to OpenAI Chat Completions |

Both `.tmpl` files are expanded via `envsubst` into `passthrough.yaml` /
`transform.yaml` (git-ignored, regenerated each run) — see Quick Start below.

## Quick Start

```bash
# Point at your vLLM endpoint (defaults to 10.0.0.99:8000 if unset)
export VLLM_ENDPOINT="${VLLM_ENDPOINT:-10.0.0.99:8000}"
envsubst < passthrough.yaml.tmpl > passthrough.yaml
envsubst < transform.yaml.tmpl > transform.yaml

# Passthrough (demos 1-3)
export ANTHROPIC_API_KEY=sk-ant-...
RUST_LOG=praxis_filter=debug cargo run -p praxis-proxy --release -- \
  -c passthrough.yaml

# Transform (demo 4)
RUST_LOG=praxis_filter=debug cargo run -p praxis-proxy --release -- \
  -c transform.yaml
```

## Prerequisites

- **Praxis** built from source (`cargo build -p praxis-proxy --release`)
- `envsubst` (`brew install gettext` on macOS) to render the `.tmpl` configs
- `ANTHROPIC_API_KEY` env var set (for Anthropic API passthrough)
- A reachable vLLM endpoint — set `VLLM_ENDPOINT` (defaults to `10.0.0.99:8000`,
  a placeholder unlikely to be reachable from your network)
