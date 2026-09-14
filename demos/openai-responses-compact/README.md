# OpenAI Responses API — History Compaction

[![asciicast](https://asciinema.org/a/EnAFDel4D9ckyCMR.svg)](https://asciinema.org/a/EnAFDel4D9ckyCMR)

A demo of **Praxis** compacting conversation history for the OpenAI
Responses API. Turn 1 is stored in SQLite. On turn 2 the client sends
only `previous_response_id` plus a `compaction` block — Praxis rehydrates
the stored history and, once it crosses `compact_threshold`, calls the
inference backend to summarize the prior turns before forwarding only the
summary plus the current question. The client never resends prior turns,
and the forwarded context stays under the token budget.

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Client asks for a long, detailed answer. Praxis classifies, validates, forwards to the backend, and stores the response in SQLite. The response ID is captured. |
| 2 | Client sends a follow-up with only `previous_response_id` and `context_management:[{type:compaction, compact_threshold:1000}]`. Praxis rehydrates the history; because it exceeds the threshold, the compact filter summarizes the prior turns via an inference callout before forwarding the current turn. |
| 3 | Client calls `POST /v1/responses/compact` explicitly. Praxis returns a `response.compaction` object with the summary output and usage — nothing is forwarded to inference. |

### Filter pipeline

```text
openai_responses_format   → classify request format and mode
openai_responses_validate → validate parameters, generate response/conversation IDs
openai_response_store      → persist response to SQLite, register store for downstream
openai_stream_events       → SSE plumbing (inert for non-streaming turns)
openai_responses_rehydrate → fetch previous response, assemble conversation history
openai_responses_compact   → summarize history when tokens exceed compact_threshold
openai_responses_proxy     → rebuild request body with the compacted context
router + load_balancer     → forward to the inference backend
```

### How compaction fires

- **Reactive** (step 2) — rehydrated history loaded via `previous_response_id`
  or `conversation`. Only the stored history is summarized; the current turn
  is preserved. Direct-input requests (full conversation inline, no stored
  history) are released without compaction — there is no separable current
  turn to preserve.
- **Explicit** (step 3) — `POST /v1/responses/compact` with a `model` and a
  `previous_response_id` and/or inline `input`. Loads stored history, appends
  inline input, summarizes, and returns a `response.compaction` object with
  `output` and `usage` per the OpenAI contract.

## Security note

`StreamBuffer` body callouts run before this listener's header-phase
security filters, so `openai_responses_compact` requires
`allow_pre_security_callout: true`. Deploy this behind an outer
authentication and authorization boundary that vets requests before they
reach the listener.

## Prerequisites

- **Ollama** on `:11434` with a small model pulled:

  ```bash
  ollama serve &            # if not already running
  ollama pull llama3.2:1b   # or export MODEL=<name>
  ```

  Ollama serves both the main `/v1/responses` inference and the
  `/v1/chat/completions` summarization callout.

- **praxis-ai** on `$PATH` (or `PRAXIS_BIN=/path/to/praxis-ai`), built
  from the `praxis-proxy/ai` repo:

  ```bash
  cargo build --release -p praxis-ai-proxy
  ```

- `asciinema`, `tmux`, `jq`, `curl`, `sqlite3`.

## Run it

```bash
praxis-ai -c compact.yaml     # terminal 1
./run-demo.sh                 # terminal 2
```

## Record it

```bash
./record.sh                   # writes demo.cast
```

`record.sh` launches Praxis and the demo runner in a split tmux session
and wraps the whole thing in `asciinema rec`. The demo runner ends the
session when it finishes, so the recording stops cleanly. Set `MODEL` and
`PRAXIS_BIN` to override defaults.

## Files

| File | Description |
|------|-------------|
| `compact.yaml` | Praxis config: full pipeline with store, rehydrate, compact, proxy |
| `record.sh` | Set up tmux + asciinema recording |
| `run-demo.sh` | Demo runner: 3-step compaction walkthrough |
| `demo.cast` | Recorded asciinema session |
