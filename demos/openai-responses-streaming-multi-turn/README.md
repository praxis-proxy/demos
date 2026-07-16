# Streaming Multi-Turn — Responses API with `previous_response_id`

[![asciicast](https://asciinema.org/a/S3PGBeG8AHxwPwhU.svg)](https://asciinema.org/a/S3PGBeG8AHxwPwhU)

A demo of **Praxis** handling streaming multi-turn conversations with the
OpenAI Responses API. Turn 1 is non-streaming and stored in SQLite. Turn 2
streams with `previous_response_id` — Praxis rehydrates the conversation
history, forwards it to vLLM, and the `openai_stream_events` filter
accumulates SSE state for persistence at end-of-stream.

## What it shows

| Step | Mode | What happens |
|------|------|--------------|
| 1 | Non-streaming | Send a request, Praxis stores the response in SQLite via the buffered path |
| 2 | Streaming + `previous_response_id` | Rehydrate history from turn 1, stream SSE events from vLLM, accumulate state, persist at end-of-stream |
| 3 | SQLite verify | Both responses (buffered and streamed) are persisted |
| 4 | GET retrieve | Fetch the stored streaming response by ID |

### Key behaviors

- **Streaming accumulation**: the `openai_stream_events` filter observes SSE
  chunks without modification, accumulates the response object, output items,
  tool calls, and usage. Terminal events (`response.completed`) overwrite
  incremental state.
- **End-of-stream persistence**: the `openai_response_store` filter persists
  the accumulated state when the stream ends — streaming responses are stored
  just like non-streaming ones.
- **Conversation rehydration**: `previous_response_id` triggers the rehydrate
  filter to load turn 1 from SQLite and prepend its message history. The
  `responses_proxy` filter rebuilds the request body with the full conversation.
- **Token count growth**: turn 2 consumes more tokens because the rehydrated
  history is included in the prompt.

## Architecture

```text
┌────────┐       ┌──────────────────────────────────┐       ┌──────┐
│ client │──────▸│        Praxis (127.0.0.1:8080)   │──────▸│ vLLM │
│ (curl) │       │                                  │       │:8000 │
└────────┘       │  format → validate → store       │       └──────┘
                 │    → stream_events → rehydrate   │
                 │    → responses_proxy → router     │
                 │                                  │
                 │  Turn 1: store ← buffered resp   │
                 │  Turn 2: rehydrate → stream SSE  │
                 │          stream_events → store    │
                 └──────────────────────────────────┘
```

## Prerequisites

- **Praxis AI** built from source (`cargo build -p praxis-ai-proxy --release`)
- **vLLM** running with an OpenAI-compatible model (e.g. `Qwen/Qwen3-0.6B`)
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start vLLM (if not already running)
podman run --name vllm -p 8000:8000 \
  vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B

# Terminal 2: start Praxis AI
cd demos/openai-responses-streaming-multi-turn
RUST_LOG=praxis_filter=debug praxis-ai -c streaming-multi-turn.yaml

# Terminal 3: turn 1 — non-streaming
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"My name is Seb and I build reverse proxies. Remember this."}' | jq .

# Save the response ID, then turn 2 — streaming with rehydration
RESP_ID=<id from above>
curl -sN http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"What is my name and what do I build?","stream":true,"previous_response_id":"'"$RESP_ID"'"}'

# Verify both responses stored
sqlite3 responses.db "SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;"
```

## Recording the demo

```bash
./record.sh
```

Play back:

```bash
asciinema play demo.cast
```

## What to look for

### SSE events

Turn 2 streams Server-Sent Events in real time:

```
event: response.output_text.delta
data: {"type":"response.output_text.delta","output_index":0,...,"delta":"Seb"}

event: response.completed
data: {"type":"response.completed","response":{...}}

event: done
data: [DONE]
```

### Praxis logs

```
classified format=openai_responses stream=false     # turn 1
store persisted id=resp_...                         # buffered store
classified format=openai_responses stream=true      # turn 2
rehydrated previous_response_id=resp_... messages=2 # history loaded
stream_events terminal response.completed           # SSE accumulated
store persisted id=resp_...                         # streaming store
```

### Token growth

Turn 2 uses more tokens than turn 1 because the rehydrated conversation
history is included in the prompt sent to vLLM.

## Files

| File | Description |
|------|-------------|
| `streaming-multi-turn.yaml` | Praxis config: full pipeline with stream_events + rehydrate |
| `record.sh` | Set up tmux + asciinema recording (3-pane layout) |
| `run-demo.sh` | Demo runner: non-streaming turn 1, streaming turn 2 |
| `demo.cast` | Recorded asciinema session |
