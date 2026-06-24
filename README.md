# Praxis demos

Runnable, self-contained demos and setups for [Praxis](https://github.com/praxis-proxy/praxis).
Each demo lives under `demos/<name>/` with its own README and bring-up script.

## Demos

| Demo | Description |
|------|-------------|
| [anthropic-messages](demos/anthropic-messages/) | Route Anthropic `/v1/messages` requests to any backend — Anthropic API, vLLM, or OpenAI-compatible — with optional format transformation via composable filters. |
| [cpex](demos/cpex/) | End-to-end CPEX policy enforcement for MCP traffic: multi-source JWT identity, APL routes with a Cedar or CEL PDP, RFC 8693 token exchange, on-the-wire redaction, PII scanning, audit, and Valkey-backed session taint. Keycloak IdP, a mock MCP server, curl scenarios, and an LLM chat client. |
| [openai-responses-stateless](demos/openai-responses-stateless/) | Stateless passthrough for OpenAI `/v1/responses` with `store: false`. Praxis classifies the request, detects stateless mode, and proxies directly to vLLM — no buffering, no persistence, no transformation. |

## Layout

```text
demos/
  <name>/
    README.md        # what it shows and how to run it
    ...              # configs, scripts, and any services
```

Each demo is independent. Start from its README.
