# OpenAI Responses API — Multi-Turn Conversation (Non-Streaming)

[![asciicast](https://asciinema.org/a/EaAMf3yreSh7W4wM.svg)](https://asciinema.org/a/EaAMf3yreSh7W4wM)

A demo of **Praxis** managing multi-turn conversations for the OpenAI
Responses API using non-streaming requests. Turn 1 is stored in SQLite.
Turn 2 sends `previous_response_id` — Praxis rehydrates the conversation
history from the store and the `responses_proxy` filter rebuilds the
request body with the full message context before forwarding to vLLM.
The client never resends prior turns.

Non-streaming is required for persistence: the store filter buffers the
complete JSON response to extract and save the output. Streaming responses
bypass persistence.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Client says "My name is Seb and I like reverse proxies." Praxis classifies, validates, forwards to vLLM, and stores the response in SQLite. |
| 2 | Client asks "What is my name and what do I like?" with `previous_response_id`. Praxis rehydrates the conversation, rebuilds the body, and forwards. If the model answers correctly, rehydration worked. |

### Filter pipeline

```text
openai_responses_format   → classify request format and mode
openai_responses_validate → validate parameters, generate response/conversation IDs
openai_response_store     → persist response to SQLite, register store for downstream
openai_responses_rehydrate → fetch previous response, assemble conversation history
responses_proxy           → rebuild request body with full message array
router + load_balancer    → forward to vLLM
```

### What happens on turn 2

1. **rehydrate** looks up `previous_response_id` in the store, loads the
   stored response and its output, and builds `ResponsesState` with the
   complete conversation (stored turns + current input)
2. **responses_proxy** reads `ResponsesState`, replaces the `input` field
   with the full message array, strips `previous_response_id` (already
   resolved), and updates `content-length`
3. vLLM receives a single request with the entire conversation context

## Architecture

```text
                          ┌──────────────────────────────────────────┐
┌────────┐                │              Praxis                      │
│ client │───Turn 1──────▸│  format → validate → store → router     │──▸ vLLM
│        │                │                        │                │    :8000
│        │                │                    ┌───▼───┐            │
│        │                │                    │SQLite │            │
│        │                │                    └───┬───┘            │
│        │───Turn 2──────▸│  format → validate → store → rehydrate │──▸ vLLM
│        │ prev_resp_id   │                              → proxy    │    :8000
└────────┘                └──────────────────────────────────────────┘
```

## Prerequisites

- **Praxis** built from source (`cargo build -p praxis-proxy --release`)
- **vLLM** running on `127.0.0.1:8000` with `/v1/responses` support
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start Praxis
cd demos/openai-responses-multi-turn
RUST_LOG=praxis_filter=debug praxis -c multi-turn.yaml

# Terminal 2: turn 1
RESP=$(curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"My name is Seb and I like reverse proxies. Acknowledge this."}')
echo "$RESP" | jq .
RESP_ID=$(echo "$RESP" | jq -r '.id')

# Terminal 2: turn 2 (rehydrated)
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"What is my name and what do I like?","previous_response_id":"'"$RESP_ID"'"}' \
  | jq .
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

### Token counts

The `total_tokens` in the response proves rehydration worked:

| Turn | total_tokens | Why |
|------|-------------|-----|
| 1 | ~243 | Single input, no history |
| 2 | ~284 | Higher — conversation history was prepended by `responses_proxy` |

Turn 2 consumes more tokens because Praxis rehydrated turn 1's messages
and rebuilt the request body with the full conversation before forwarding.

### Praxis logs

**Turn 1** — classified, validated, stored:

```
classified request body format="openai_responses"
persisted response id=resp_... status=completed
```

**Turn 2** — rehydrated and rebuilt:

```
classified request body format="openai_responses"
rehydrating previous_response_id=resp_...
responses_proxy rebuilding body with N messages
```

### SQLite verification

At the end of the demo, a `sqlite3` query shows both responses persisted:

```
sqlite3 responses.db "SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;"
resp_abc|Qwen/Qwen3-0.6B|2026-06-25 12:00:01
resp_def|Qwen/Qwen3-0.6B|2026-06-25 12:00:05
```

Two rows = two stored turns. The rehydrate filter reads from this store
when `previous_response_id` is set.

## Files

| File | Description |
|------|-------------|
| `multi-turn.yaml` | Praxis config: full pipeline with store, rehydrate, proxy |
| `record.sh` | Set up tmux + asciinema recording |
| `run-demo.sh` | Demo runner: two-turn conversation |
| `demo.cast` | Recorded asciinema session |
