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
| [openai-responses-file-resolve](demos/openai-responses-file-resolve/) | File resolution + document extraction — send a `file_id` in a Responses API request, Praxis resolves it via OGX, extracts text content, and converts `input_file` → `input_text` for vLLM. |
| [openai-responses-agentic-loop](demos/openai-responses-agentic-loop/) | Server-side agentic loop — model calls an MCP tool, Praxis dispatches to the MCP server and loops the result back to the model for a final answer. No client-side orchestration needed. |
| [openai-responses-file-search](demos/openai-responses-file-search/) | Server-side file search — model calls file_search, Praxis dispatches to OGX's vector store search API, loops back with ranked results, and the model answers grounded in retrieved documents. |
| [skillberry-agent-proxy](demos/skillberry-agent-proxy/) | A fully automated demo of Praxis as an agentic gateway for the Skillberry Agent platform, based on [skillberry-agent-praxis-poc](https://github.com/skillberry-ai/skillberry-agent-praxis-poc) |

## Grid QuickStarts

Multi-cluster Grid demos that prove distributed inference routing with
runtime assertions. Each demo requires a local
[praxis-proxy/grid](https://github.com/praxis-proxy/grid) checkout
(or set `GRID_REPO`), Docker, kind, and Rust.

| Demo | Description |
|------|-------------|
| [grid-glb-demo](demos/grid-glb-demo/) | Local GTM emulator, multiple active edges, independent provider selection |
| [grid-workload-inference](demos/grid-workload-inference/) | Cluster-local workload entry without public ingress |
| [grid-llmd-pool-metrics](demos/grid-llmd-pool-metrics/) | EPP telemetry, Grid scoring, A-to-B-to-A capacity failover |
| [grid-combined-site](demos/grid-combined-site/) | Consumer and secured provider roles colocated at each site |

## Grid Labs and Guides

Script-driven Grid demos and reference guides for specific topics.

| Demo | Description |
|------|-------------|
| [grid-route53-edge-entry](demos/grid-route53-edge-entry/) | Route 53 DNS edge selection with Grid provider routing on existing OpenShift clusters |
| [grid-metrics-mtls](demos/grid-metrics-mtls/) | Secret-backed TLS and mTLS for InferenceProvider metrics scraping |

## MaaS Labs

| Demo | Description |
|------|-------------|
| [maas-ipp](demos/maas-ipp/) | Single-cluster MaaS IPP lab reproducing the stock MaaS Kind datapath with Forge |

## Layout

```text
demos/
  <name>/
    README.md        # what it shows and how to run it
    ...              # configs, scripts, and any services
```

Each demo is independent. Start from its README.
