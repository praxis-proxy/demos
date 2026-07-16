# OpenAI Responses API — Stateless Passthrough

[![asciicast](https://asciinema.org/a/qKPCNIAZjOVm9Fyu.svg)](https://asciinema.org/a/qKPCNIAZjOVm9Fyu)

A minimal demo of **Praxis** proxying OpenAI `/v1/responses` requests with
`store: false` to a vLLM backend. The request is classified, routed, and
forwarded unchanged — sub-millisecond overhead, no buffering, no persistence,
no transformation.

## What it shows

The OpenAI Responses API defaults to `store: true`, which implies stateful
behavior (conversation history, tool dispatch, persistence). When a client
sets `store: false` and includes no other stateful markers, Praxis detects
this and takes the **stateless fast path**: the request bypasses the entire
orchestration filter chain and is proxied directly to the inference backend.

| Step | Path | What happens |
|------|------|--------------|
| 1 | curl → vLLM | Baseline: hit vLLM directly, no proxy |
| 2 | curl → Praxis → vLLM | Stateless passthrough (`store: false`) |
| 3 | curl → Praxis → vLLM | Same, with `stream: true` (SSE forwarded as-is) |

### Stateless vs stateful

A request is **stateful** if any of these are present:

- `store` is `true` (or omitted — the OpenAI spec default)
- `previous_response_id` is set
- `tools` array is non-empty
- `background` is `true`
- `conversation` is set
- `prompt_id` is set

**Stateless** requires `store: false` and none of the above.

## Architecture

```text
┌────────┐       ┌──────────────────────────┐       ┌──────┐
│ client │──────▸│  Praxis (127.0.0.1:8080) │──────▸│ vLLM │
│ (curl) │       │                          │       │:8000 │
└────────┘       │  openai_responses_format  │       └──────┘
                 │    ↓ mode=stateless       │
                 │  router → load_balancer   │
                 └──────────────────────────┘
```

The `openai_responses_format` filter reads the request body (without mutating
it), classifies the mode, and sets a filter result. Stateful requests enter a
branch chain for orchestration. Stateless requests skip the branch and fall
through to the router — direct proxy to the backend.

## Prerequisites

- **Praxis** built from source (`cargo build -p praxis --release`)
- **vLLM** running on `127.0.0.1:8000` with `/v1/responses` support
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start Praxis
RUST_LOG=praxis_filter=debug cargo run -p praxis --release -- \
  -c passthrough.yaml

# Terminal 2: send a stateless request
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"Why is Kubernetes awesome? Reply in one sentence.","store":false}' \
  | jq .
```

## Recording the demo

The recording script sets up a tmux session with three panes (vLLM logs,
Praxis logs, curl commands) and captures it with asciinema:

```bash
./record.sh
```

Play back:

```bash
asciinema play demo.cast
```

## What to look for in the logs

When a stateless request flows through Praxis, the debug logs show:

```
classified request body format="openai_responses" model=Some("Qwen/Qwen3-0.6B")
route matched path=/v1/responses cluster=vllm
upstream selected cluster=vllm upstream=127.0.0.1:8000
```

No branch chain entered, no persistence, no body mutation — straight through.

## Files

| File | Description |
|------|-------------|
| `passthrough.yaml` | Praxis config: classify mode, route to vLLM |
| `record.sh` | Set up tmux + asciinema recording |
| `run-demo.sh` | Demo runner with typed curl commands |
| `demo.cast` | Recorded asciinema session |
