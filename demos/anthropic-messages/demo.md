# Anthropic Messages API Filters — Demo

---

## Setup

```
# Terminal 1 (Praxis logs)
RUST_LOG=praxis_filter=debug cargo run -p praxis-proxy --release -- -c passthrough.yaml 2>&1 \
  | grep -E 'classified|validation|route matched|upstream selected|credential|transformed|streaming'

# Terminal 2 (curl)
```

---

## Intro

This is a light demo of the Anthropic Messages API filters in Praxis.

Major caveats that this is still a work in progress and needs more validation,
but the goal is to show how far we can get with composable filters.

## Goal

Accept Anthropic `/v1/messages` requests and route them to any backend —
Anthropic API, vLLM, or OpenAI-compatible — with optional format transformation.

There are five composable filters (classify, validate JSON, set protocol headers, transform, stream)
wired via Praxis' YAML config. And there are no code changes to swap backends.

## 1. Direct to Anthropic (no proxy)

> First, let's hit Anthropic directly to confirm the API works. No proxy involved.

```bash
curl -s https://api.anthropic.com/v1/messages \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 128,
    "messages": [{"role": "user", "content": "Why is Red Hat awesome?"}]
  }' | jq .
```

---

## 2. Praxis → Anthropic API (/v1/messages passthrough)

> Now the same request goes through Praxis. It classifies the format, validates the JSON envelope, injects credentials, and proxies to Anthropic. Same response, zero changes to the request.

```bash
curl -s http://127.0.0.1:8080/v1/messages \
  -H "Host: api.anthropic.com" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "claude-haiku-4-5",
    "max_tokens": 128,
    "messages": [{"role": "user", "content": "Why is Red Hat awesome?"}]
  }' | jq .
```

---

## 3. Praxis → vLLM (/v1/messages passthrough)

> Same Anthropic-format request, but now routed to vLLM with gpt-oss 20b. The backend speaks Messages natively — Praxis just forwards it. Different backend, zero code change.

```bash
curl -s http://127.0.0.1:8080/v1/messages \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "max_tokens": 128,
    "system": "Reply concisely.",
    "messages": [{"role": "user", "content": "Why is Red Hat awesome?"}]
  }' | jq .
```

---

## 4. Praxis → vLLM (/v1/chat/completions transform)

> Now the interesting part. We restart Praxis with a transform config — the transform filter needs body hooks to rewrite request and response payloads, and body hooks don't run inside branch chains, so we swap the config rather than routing conditionally. Same Anthropic request goes in, Praxis transforms it to OpenAI, sends to /v1/chat/completions, and transforms the response back. The client never knows.

```
# Restart Praxis with the transform config
RUST_LOG=praxis_filter=debug cargo run -p praxis-proxy --release -- -c transform.yaml
```

```bash
curl -s http://127.0.0.1:8080/v1/messages \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "openai/gpt-oss-20b",
    "max_tokens": 128,
    "system": "Reply concisely.",
    "messages": [{"role": "user", "content": "Why is Red Hat awesome?"}]
  }' | jq .
```

---

## Filters

| Filter | What it does |
|--------|-------------|
| `anthropic_messages_format` | Classify request format |
| `anthropic_validate` | Validate the JSON request envelope |
| `anthropic_messages_protocol` | Inject anthropic-version header |
| `anthropic_to_openai` | Transform request/response body |
| `anthropic_stream_events` | Per-chunk SSE transformation |
