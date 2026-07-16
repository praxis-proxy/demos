# OpenAI Conversations API — Local CRUD

[![asciicast](https://asciinema.org/a/URvXBYekHHzIXv51.svg)](https://asciinema.org/a/URvXBYekHHzIXv51)

A demo of **Praxis** serving the OpenAI `/v1/conversations` API entirely
locally. All conversation and item operations are handled by the
`openai_conversations` filter backed by SQLite — nothing is forwarded
upstream. No inference backend needed.

## What it shows

| Step | Endpoint | What happens |
|------|----------|--------------|
| 1 | `POST /v1/conversations` | Create a conversation with metadata and an initial user item |
| 2 | `GET /v1/conversations/{id}` | Retrieve the conversation |
| 3 | `POST /v1/conversations/{id}/items` | Add an assistant reply |
| 4 | `GET /v1/conversations/{id}/items` | List all items in the conversation |
| 5 | `GET /v1/conversations/{id}/items/{item_id}` | Retrieve a single item by ID |
| 6 | `POST /v1/conversations/{id}` | Update metadata (staging → production) |
| 7 | `DELETE /v1/conversations/{id}/items/{item_id}` | Delete the assistant item, verify 404 |
| 8 | `DELETE /v1/conversations/{id}` | Delete the conversation (items preserved) |
| 9 | `sqlite3` | Verify the user item survives deletion |

All requests return OpenAI-compatible JSON — the official Python SDK
works against this endpoint out of the box.

### Key behaviors

- **Fully local**: every `/v1/conversations` request is handled by
  Praxis via `FilterAction::Reject` — no upstream backend involved
- **Items survive conversation deletion**: deleting a conversation
  soft-deletes the conversation record but preserves item rows for audit
- **Individual item lifecycle**: items can be retrieved and deleted
  individually via their `item_id`
- **Metadata validation**: max 16 keys, key ≤ 64 bytes, value ≤ 512 bytes
- **SQLite or PostgreSQL**: the filter supports both backends

## Architecture

```text
┌────────┐       ┌──────────────────────────────────┐
│ client │──────▸│        Praxis (127.0.0.1:8080)   │
│ (curl) │       │                                  │
└────────┘       │  openai_conversations filter     │
                 │    ↓ route by method + path       │
                 │  create / get / update / delete   │
                 │    ↓                              │
                 │  ┌──────────┐                     │
                 │  │  SQLite  │                     │
                 │  └──────────┘                     │
                 └──────────────────────────────────┘
                    (no upstream — all local)
```

## Prerequisites

- **Praxis AI** built from source (`cargo build -p praxis-ai-proxy --release`)
- **tmux** and **asciinema** (for recording only)
- No inference backend required

## Quick start

```bash
# Terminal 1: start Praxis AI
cd demos/openai-conversations
RUST_LOG=praxis_filter=debug praxis-ai -c conversations.yaml

# Terminal 2: create a conversation with an initial item
curl -s http://127.0.0.1:8080/v1/conversations \
  -H "Content-Type: application/json" \
  -d '{"metadata":{"project":"demo"},"items":[{"type":"message","role":"user","content":"hello"}]}' | jq .

# Add an assistant reply
CONV_ID=<id from above>
curl -s http://127.0.0.1:8080/v1/conversations/$CONV_ID/items \
  -H "Content-Type: application/json" \
  -d '{"items":[{"type":"message","role":"assistant","content":"hi there"}]}' | jq .

# List items
curl -s "http://127.0.0.1:8080/v1/conversations/$CONV_ID/items?order=asc" | jq .

# Retrieve a single item
ITEM_ID=<item_id from above>
curl -s http://127.0.0.1:8080/v1/conversations/$CONV_ID/items/$ITEM_ID | jq .
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

### Response format

Every response follows the OpenAI wire format:

```json
{
  "id": "conv_abc123",
  "object": "conversation",
  "created_at": 1751234567,
  "metadata": {"project": "praxis-demo", "env": "staging"}
}
```

### Item lifecycle

Items have their own CRUD — each item gets an `item_id` and can be
retrieved or deleted individually:

```json
{
  "id": "item_abc123",
  "type": "message",
  "role": "user",
  "status": "completed",
  "content": [{"type": "input_text", "text": "What is a reverse proxy?"}]
}
```

### Items persist after conversation deletion

After deleting the conversation (step 8), the SQLite query (step 9) shows
the remaining user item is still in the database. The assistant item was
already deleted in step 7.

```
sqlite3 conversations.db "SELECT item_id, json_extract(item_data, '$.role'), json_extract(item_data, '$.content[0].text') FROM openai_conversation_items WHERE conversation_id='conv_...' ORDER BY position;"
```

### Praxis logs

```
conversation created id=conv_...
conversation items created count=1
conversation updated id=conv_...
conversation item deleted id=item_...
conversation deleted id=conv_...
```

All handled locally — no upstream connection attempted.

## Files

| File | Description |
|------|-------------|
| `conversations.yaml` | Praxis config: conversations filter with SQLite backend |
| `record.sh` | Set up tmux + asciinema recording |
| `run-demo.sh` | Demo runner: full CRUD lifecycle with item operations |
| `demo.cast` | Recorded asciinema session |
