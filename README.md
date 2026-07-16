# Praxis demos

Runnable, self-contained demos and setups for [Praxis](https://github.com/praxis-proxy/praxis).
Each demo lives under `demos/<name>/` with its own README and bring-up script.

## Demos

| Demo | Description |
|------|-------------|
| [anthropic-messages](demos/anthropic-messages/) | Route Anthropic `/v1/messages` requests to any backend — Anthropic API, vLLM, or OpenAI-compatible — with optional format transformation via composable filters. |
| [authpolicy-transpiler](demos/authpolicy-transpiler/) | Offline CLI that transpiles a Kuadrant `AuthPolicy` into Praxis policy config (a `policy`-filter block plus a CPEX policy document), with a coverage report showing what maps to CEL and what is out of scope. |
| [cpex-policy-engine](demos/cpex/) | Policy enforcement on MCP traffic: authorization flows connecting identity to access control decisions with Cedar or CEL PDP, delegation, out-of-band elicitation, data redaction, and session tainting. |
| [openai-responses-stateless](demos/openai-responses-stateless/) | Stateless passthrough for OpenAI `/v1/responses` with `store: false`. Praxis classifies the request, detects stateless mode, and proxies directly to vLLM — no buffering, no persistence, no transformation. |
| [openai-responses-codex-passthrough](demos/openai-responses-codex-passthrough/) | Live Codex CLI passthrough to the OpenAI Responses API. Demonstrates model alias rewriting, default injection, effective-model headers, SSE, and a Codex-owned tool loop. Run the [all-in-one narrated demo](demos/openai-responses-codex-passthrough/README.md#all-in-one-recommended) or each [step individually](demos/openai-responses-codex-passthrough/README.md#step-by-step-multi-terminal). |
| [openai-responses-multi-turn](demos/openai-responses-multi-turn/) | Multi-turn conversation (non-streaming) for the OpenAI Responses API. Praxis stores turn 1 in SQLite, then rehydrates the conversation history on turn 2 via `previous_response_id` and rebuilds the request body before forwarding to vLLM. |
| [openai-responses-streaming-multi-turn](demos/openai-responses-streaming-multi-turn/) | Streaming multi-turn with `previous_response_id`. Turn 1 non-streaming stored in SQLite, turn 2 streaming with rehydrated history — SSE events accumulated by `openai_stream_events` and persisted at end-of-stream. |
| [openai-conversations](demos/openai-conversations/) | Full CRUD lifecycle for the OpenAI `/v1/conversations` API handled entirely locally by Praxis — create, retrieve, update, delete conversations and items, all backed by SQLite with no upstream traffic. |
| [openai-conversations-multi-turn](demos/openai-conversations-multi-turn/) | Multi-turn via `conversation` field — create a conversation, reference it by ID on each turn. Praxis rehydrates stored items, forwards full context to vLLM, and auto-appends input+output back to the conversation. |

## Layout

```text
demos/
  <name>/
    README.md        # what it shows and how to run it
    ...              # configs, scripts, and any services
```

Each demo is independent. Start from its README.
