# Anthropic Messages API in Praxis

## Goal

Accept Anthropic `/v1/messages` requests and route them to any backend —
Anthropic API, vLLM, or OpenAI-compatible — with optional format transformation.

## Demo
1. **Direct** — curl → Anthropic API
2. **Passthrough** — curl → Praxis → Anthropic API (`/v1/messages`)
3. **vLLM native** — curl → Praxis → vLLM (`/v1/messages`)
4. **Transform** — curl → Praxis → vLLM (`/v1/chat/completions`, auto-converted)

## How
Five composable filters — classify, validate JSON, set protocol headers, transform, stream —
wired via YAML config. No code changes to swap backends.

## Filters

| Filter | What it does |
|--------|-------------|
| `anthropic_messages_format` | Classify request format |
| `anthropic_validate` | Validate the JSON request envelope |
| `anthropic_messages_protocol` | Inject anthropic-version header |
| `anthropic_to_openai` | Transform request/response body |
| `anthropic_stream_events` | Per-chunk SSE transformation |
