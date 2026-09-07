# Streaming Agentic Loop — SSE Across IRR Rounds

[![asciicast](https://asciinema.org/a/Owae1Ri9RwfISTDG.svg)](https://asciinema.org/a/Owae1Ri9RwfISTDG)

A demo of **Praxis** streaming a Responses API answer as **one logical SSE
stream preserved across multiple agentic rounds**. When the model calls a
tool mid-stream, Praxis streams round 1 (the tool call), withholds the
terminal `response.completed`, dispatches the tool (web search or MCP),
then streams round 2 (the final answer). The client sees a single
continuous stream — one `response.created` and one `response.completed`
at the very end — even though several inference rounds happened inside.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Simple streaming, no tools — SSE deltas through IRR terminal streaming, single round |
| 2 | Streaming + web search (Tavily) — model calls web_search, Praxis dispatches, streams grounded answer |
| 3 | Streaming + MCP tool call — model calls get_weather, Praxis dispatches to MCP, streams final answer |

### Key behaviors

- **One logical stream across rounds**: `openai_stream_events` with
  `logical_stream: true` preserves a single response identity and
  withholds each round's terminal event until the loop decision is
  known — so multiple rounds surface as one `response.created` /
  `response.completed` pair
- **Typed SSE transport**: `openai_responses_proxy` with
  `terminal_streaming: true` selects Praxis's typed streaming transport
  for `stream: true` requests
- **Fail-closed pairing**: `terminal_streaming` requires
  `logical_stream: true`. Typed streaming commits `response.completed`
  as it arrives, so a loop-terminal error (SSE parse failure, tool-call
  cardinality violation) can only reach the client through the
  logical-stream finalizer, which defers each round's terminal event and
  can replace it with an error frame
- **Streamed tool dispatch**: web search (Tavily) and MCP calls both
  execute between streamed rounds and resume inference on the same
  downstream SSE lifecycle
- **No client-side orchestration**: the client sends one streaming
  request and consumes one stream — Praxis runs the whole loop

## Architecture

```text
┌────────┐  stream=true  ┌──────────────────────────────────────────────┐
│ client │◀═════════════▶│            Praxis (127.0.0.1:8080)           │
│ (curl) │   one logical │                                              │
└────────┘   SSE stream  │  format → validate → tool_parse              │
                         │    → store → rehydrate → mcp_tool_resolve    │
                         │                                              │
                         │  ┌─ iterative_request_router ─────────────┐  │
                         │  │  stream_events(logical_stream)         │  │
                         │  │   → web_search → mcp_dispatch          │  │
                         │  │   → agentic_loop                       │  │
                         │  │   → responses_proxy(terminal_streaming)│  │
                         │  │   → router ────────────────────────────│──│──▸ vLLM (:8000)  [streamed]
                         │  │                                        │  │
                         │  │  round 1 streams tool call             │  │
                         │  │   (response.completed WITHHELD)        │  │
                         │  │    web_search ─────────────────────────│──│──▸ Tavily (api.tavily.com)
                         │  │    mcp_dispatch ───────────────────────│──│──▸ MCP (:9100)
                         │  │  round 2 streams final answer          │  │
                         │  │   (response.completed EMITTED once)    │  │
                         │  └────────────────────────────────────────┘  │
                         └──────────────────────────────────────────────┘
```

## Prerequisites

- **Praxis AI** built from source (`cargo build -p praxis-ai-proxy --release`)
- **vLLM** running with a tool-calling model (e.g. `Qwen/Qwen3-0.6B`)
- **Python 3** (for the mock MCP server)
- **Tavily API key** in `TAVILY_API_KEY` (for the web search step)
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start vLLM
podman run --name vllm -p 8000:8000 \
  vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B

# Terminal 2: start the mock MCP server
cd demos/openai-responses-streaming-agentic-loop
python3 mcp_server.py

# Terminal 3: start Praxis AI (Tavily key in env for web search)
cd demos/openai-responses-streaming-agentic-loop
TAVILY_API_KEY=tvly-... \
  RUST_LOG=praxis_filter=debug praxis-ai -c streaming-agentic-loop.yaml

# Terminal 4: stream a request with an MCP tool
curl -sN http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "input": "What is the weather in San Francisco? /no_think",
    "stream": true,
    "tools": [{
      "type": "mcp",
      "server_label": "weather",
      "server_url": "http://127.0.0.1:9100/mcp",
      "allowed_tools": ["get_weather"],
      "require_approval": "never"
    }]
  }'
```

## Recording the demo

```bash
TAVILY_API_KEY=tvly-... ./record.sh
```

Play back:

```bash
asciinema play demo.cast
```

## What to look for

### The stream itself (curl pane)

```
event: response.created                       # exactly ONCE
data: {"type":"response.created", ...}
...
event: response.function_call_arguments.delta # round 1: tool call streams in
...
event: response.output_text.delta             # round 2: answer streams in
data: {"type":"response.output_text.delta", "delta":"72"}
...
event: response.completed                      # exactly ONCE, at the very end
```

The runner counts `response.created` and `response.completed` — both are
`1` even for multi-round tool requests. That's the proof: one logical
stream across rounds.

### Praxis logs

```
classified format=openai_responses            # request classified
stream_events logical_stream armed            # per-round terminals deferred
round 1: inference (streamed)                 # first streamed inference
agentic_loop detected tool call               # model wants a tool
mcp_dispatch / web_search executing           # dispatch between rounds
transition action=loop next=inference         # loop back, same stream
round 2: inference (streamed)                 # second streamed inference
response.completed emitted                     # single terminal to client
```

### What vLLM sees

Two **streamed** inference calls per tool request:

1. **Round 1**: user message + tool definitions (model streams a tool call)
2. **Round 2**: user message + tool definitions + tool result (model streams the final answer)

## Files

| File | Description |
|------|-------------|
| `streaming-agentic-loop.yaml` | Praxis config: IRR + logical_stream + terminal_streaming + web_search + MCP |
| `mcp_server.py` | Mock MCP server with `get_weather` tool (port 9100) |
| `record.sh` | Set up tmux + asciinema recording (4-pane layout) |
| `run-demo.sh` | Demo runner: simple stream, web search stream, MCP stream |
| `demo.cast` | Recorded asciinema session |
