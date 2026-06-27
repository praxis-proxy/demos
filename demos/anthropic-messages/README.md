# Anthropic Messages API Demo

Demonstrates routing Anthropic `/v1/messages` requests through Praxis
to different backends with optional format transformation.

## Files

| File | Description |
|------|-------------|
| `goals.md` | One-page summary of what this demo covers |
| `demo.md` | Step-by-step walkthrough with curl commands |
| `passthrough.yaml` | Config: classify, validate JSON envelopes, route by model to Anthropic API or vLLM |
| `transform.yaml` | Config: transform Anthropic Messages to OpenAI Chat Completions |

## Quick Start

```bash
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
- `ANTHROPIC_API_KEY` env var set (for Anthropic API passthrough)
- vLLM endpoint at `10.0.0.99:8000` (update `passthrough.yaml` /
  `transform.yaml` for your setup)
