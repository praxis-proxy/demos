# File Search — Vector Store Callout via OGX

[![asciicast](https://asciinema.org/a/LRVpPclFGXeaWUCI.svg)](https://asciinema.org/a/LRVpPclFGXeaWUCI)

A demo of **Praxis** executing server-side file search: the model emits a
`file_search_call`, Praxis dispatches to OGX's vector store search API,
feeds the ranked results back as model context, and the model produces a
final answer grounded in the retrieved documents. No client-side RAG
pipeline needed — the proxy handles the entire search-and-answer loop.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Create a FAISS-backed vector store in OGX |
| 2 | Upload a document and attach it to the vector store, wait for indexing |
| 3 | File search query (request volume) — model calls file_search, Praxis dispatches to OGX, loops back with results |
| 4 | File search query (security measures) — same flow, different question |
| 5 | Cleanup — delete vector store and file |

### Key behaviors

- **Server-side file search**: the `iterative_request_router` drives
  the model → search → model cycle entirely within the proxy
- **Vector store callout**: `openai_file_search_callout` dispatches
  `file_search_call` items to OGX's `/v1/vector_stores/{id}/search`
  endpoint with bounded fan-out and ranked aggregation
- **vLLM translation**: vLLM emits `function_call(name=file_search)`
  instead of native `file_search_call` — Praxis translates
  automatically before execution
- **Citation tracking**: file search results include `file_id` →
  filename mappings for downstream citation annotation
- **Fail-closed by default**: if the vector store callout fails,
  the request is rejected (configurable to fail-open)
- **No client-side RAG**: the client sends a question with
  `vector_store_ids`, and gets back an answer with citations

## Architecture

```text
┌────────┐       ┌──────────────────────────────────────────────┐
│ client │──────▸│            Praxis (127.0.0.1:8080)           │
│ (curl) │       │                                              │
└────────┘       │  format → validate                           │
                 │                                              │
                 │  ┌─ iterative_request_router ─────────────┐  │
                 │  │                                        │  │
                 │  │  tool_parse → file_search_callout      │  │
                 │  │    → responses_proxy → router ─────────│──│──▸ vLLM (:8000)
                 │  │                                        │  │
                 │  │  model emits file_search_call?         │  │
                 │  │    yes → file_search_callout ──────────│──│──▸ OGX (:8321)
                 │  │          search vector store           │  │   /v1/vector_stores/{id}/search
                 │  │          loop back with results        │  │
                 │  │    no  → done, return to client        │  │
                 │  └────────────────────────────────────────┘  │
                 └──────────────────────────────────────────────┘
```

## Prerequisites

- **Praxis AI** built from source (`cargo build -p praxis-ai-proxy --release`)
- **OGX** running on `:8321` with vector store and embedding support
- **vLLM** running with a tool-calling model (e.g. `Qwen/Qwen3-0.6B`)
- **tmux** and **asciinema** (for recording only)

## Quick start

```bash
# Terminal 1: start OGX (Files + Vector Store API on :8321)
cd /path/to/ogx
uv run ogx run starter --insecure

# Terminal 2: start vLLM
podman run --name vllm -p 8000:8000 \
  vllm/vllm-openai:latest --model Qwen/Qwen3-0.6B

# Terminal 3: start Praxis AI
cd demos/openai-responses-file-search
RUST_LOG=praxis_filter=debug praxis-ai -c file-search.yaml

# Terminal 4: create a vector store, upload a file, and search
STORE_ID=$(curl -s http://127.0.0.1:8321/v1/vector_stores \
  -H "Content-Type: application/json" \
  -d '{"name":"demo","embedding_model":"sentence-transformers/nomic-ai/nomic-embed-text-v1.5","embedding_dimension":768,"provider_id":"faiss"}' \
  | jq -r '.id')

FILE_ID=$(curl -s http://127.0.0.1:8321/v1/files \
  -F purpose=assistants \
  -F "file=@sample-doc.txt" | jq -r '.id')

curl -s http://127.0.0.1:8321/v1/vector_stores/$STORE_ID/files \
  -H "Content-Type: application/json" \
  -d "{\"file_id\":\"$FILE_ID\"}"

# Wait for indexing to complete, then query
curl -s http://127.0.0.1:8080/v1/responses \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-0.6B",
    "input": "Use the file_search tool to find how many requests Praxis processed. /no_think",
    "tools": [{"type": "file_search", "vector_store_ids": ["'"$STORE_ID"'"]}],
    "include": ["file_search_call.results"],
    "store": false,
    "max_output_tokens": 512
  }' | jq .
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

### OGX logs

```
POST /v1/vector_stores → 200              # create vector store
POST /v1/files → 200                      # upload file
POST /v1/vector_stores/{id}/files → 200   # attach file
POST /v1/vector_stores/{id}/search → 200  # search query (from Praxis)
```

### Praxis logs

```
classified format=openai_responses            # request classified
iteration 1: inference                        # first inference call
tool_parse translated function_call           # vLLM file_search → file_search_call
file_search_callout fan-out                   # dispatching to OGX vector store
transition pending=true next=inference        # loop back with search results
iteration 2: inference                        # second inference call with context
done                                          # final answer returned
```

### What vLLM sees

Two inference calls per file search request:

1. **Initial**: user message + file_search tool definition (model emits `function_call(name=file_search)`)
2. **Post-search**: user message + tool definition + search results as context (model produces final answer)

## Files

| File | Description |
|------|-------------|
| `file-search.yaml` | Praxis config: IRR + file_search_callout + OGX vector store |
| `sample-doc.txt` | Sample document uploaded to OGX for vector store indexing |
| `record.sh` | Set up tmux + asciinema recording (4-pane layout) |
| `run-demo.sh` | Demo runner: create store, upload, search queries, cleanup |
| `demo.cast` | Recorded asciinema session |
