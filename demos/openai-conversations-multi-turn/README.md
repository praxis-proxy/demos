# Conversations Multi-Turn — Rehydrate & Append-Back

[![asciicast](https://asciinema.org/a/6NaO0HSjiy3m5aoR.svg)](https://asciinema.org/a/6NaO0HSjiy3m5aoR)

A demo of **Praxis** managing multi-turn conversations automatically via
the `conversation` field in Responses API requests. The client creates a
conversation once, then references it by ID on each turn — Praxis
rehydrates the stored history, forwards the full context to vLLM, and
appends input+output items back to the conversation after each response.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Create a conversation with metadata via `POST /v1/conversations` |
| 2 | Turn 1: send a Responses request with `"conversation": "conv_..."` — Praxis forwards to vLLM and appends items back |
| 3 | List conversation items — input + output from turn 1 were auto-appended |
| 4 | Turn 2: same conversation ID — Praxis rehydrates history, model remembers turn 1 |
| 5 | List items again — conversation grew with turn 2's items |
| 6 | SQLite verification — all items persisted with roles and content |

### Key behaviors

- **Automatic append-back**: after a successful non-streaming response,
  the `openai_conversations` filter appends the user input and assistant
  output items back to the conversation. No client-side bookkeeping.
- **Conversation rehydration**: the `openai_responses_rehydrate` filter
  loads stored conversation items and prepends them to the input. The
  `responses_proxy` rebuilds the body with the full history.
- **`conversation` field stripped**: the field is removed from the outbound
  request — the backend sees a standard Responses API body with the full
  input array.
- **Token growth**: turn 2 uses more tokens than turn 1 because the
  rehydrated history is included in the prompt.
- **`previous_response_id` precedence**: when both `conversation` and
  `previous_response_id` are present, `previous_response_id` wins.

## Architecture

```text
┌────────┐       ┌──────────────────────────────────────────┐       ┌──────┐
│ client │──────▸│          Praxis (127.0.0.1:8080)         │──────▸│ vLLM │
│ (curl) │       │                                          │       │:8000 │
└────────┘       │  conversations → format → validate       │       └──────┘
                 │    → store → rehydrate → responses_proxy │
                 │                                          │
                 │  Request path:                           │
                 │    rehydrate loads conv items → prepend  │
                 │    responses_proxy strips conversation   │
                 │                                          │
                 │  Response path:                          │
                 │    conversations appends input+output    │
                 │    store persists the response           │
                 └──────────────────────────────────────────┘
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
cd demos/openai-conversations-multi-turn
RUST_LOG=praxis_filter=debug praxis-ai -c conversations-multi-turn.yaml

# Terminal 3: create a conversation
CONV_ID=$(curl -s http://127.0.0.1:8080/v1/conversations \
  -H "Content-Type: application/json" \
  -d '{"metadata":{"project":"demo"}}' | jq -r '.id')

# Turn 1 — with conversation field
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"My name is Seb.","conversation":"'"$CONV_ID"'"}' | jq .

# Check items were appended
curl -s "http://127.0.0.1:8080/v1/conversations/$CONV_ID/items?order=asc" | jq .

# Turn 2 — rehydrated
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-0.6B","input":"What is my name?","conversation":"'"$CONV_ID"'"}' | jq .
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

### Conversation growth

After each turn, list items to see the conversation growing:

```bash
curl -s "http://localhost:8080/v1/conversations/$CONV_ID/items?order=asc" | jq '.data | length'
# Turn 0: 0 items
# Turn 1: 2 items (user input + assistant output)
# Turn 2: 4 items (+ turn 2's input + output)
```

### Praxis logs

```
conversation created id=conv_...                    # step 1
classified format=openai_responses                  # turn 1
rehydrated conversation=conv_... items=0            # empty on first turn
store persisted id=resp_...                         # response stored
conversation items appended count=2                 # append-back
rehydrated conversation=conv_... items=2            # turn 2 loads history
conversation items appended count=2                 # turn 2 append-back
```

### Token growth

Turn 2 uses more tokens than turn 1 because the rehydrated conversation
history is included in the prompt sent to vLLM.

## Files

| File | Description |
|------|-------------|
| `conversations-multi-turn.yaml` | Praxis config: conversations + full responses pipeline |
| `record.sh` | Set up tmux + asciinema recording (3-pane layout) |
| `run-demo.sh` | Demo runner: create conversation, two turns, verify items |
| `demo.cast` | Recorded asciinema session |
