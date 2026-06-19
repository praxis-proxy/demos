# Praxis demos

Runnable, self-contained demos and setups for [Praxis](https://github.com/praxis-proxy/praxis).
Each demo lives under `demos/<name>/` with its own README and bring-up script.

## Demos

| Demo | Description |
|------|-------------|
| [cpex](demos/cpex/) | End-to-end CPEX policy enforcement for MCP traffic: multi-source JWT identity, APL routes with a Cedar or CEL PDP, RFC 8693 token exchange, on-the-wire redaction, PII scanning, audit, and Valkey-backed session taint. Keycloak IdP, a mock MCP server, curl scenarios, and an LLM chat client. |

## Layout

```text
demos/
  <name>/
    README.md        # what it shows and how to run it
    ...              # configs, scripts, and any services
```

Each demo is independent. Start from its README.
