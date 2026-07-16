# OpenAI Responses API - Codex Passthrough

A manual, live demonstration of a real Codex CLI session using Praxis as its
OpenAI Responses API provider. Praxis receives native `/v1/responses` traffic,
rewrites the client-facing model name, and forwards the request to OpenAI.

This is an interoperability demo, not a mock or a proxy-only benchmark. It
uses a caller-supplied OpenAI project key and incurs normal upstream API costs.

## At A Glance

| Concern | Demo behavior |
|---|---|
| Client | Real Codex CLI in `wire_api = "responses"` mode |
| Gateway | Praxis on a local loopback listener |
| Upstream | OpenAI `/v1/responses` over TLS |
| Authentication | Codex and `curl` pass `OPENAI_API_KEY` through Praxis |
| Client model | `codex-openai-demo` |
| Upstream model | Configured with `OPENAI_MODEL` |
| Evidence | Successful aliased/default requests, Praxis routing logs, JSON/SSE captures, Codex JSONL, and a proof file |

## What It Demonstrates

- A Codex custom provider can point at Praxis rather than directly at OpenAI.
- Praxis rewrites `codex-openai-demo` to the configured upstream model before
  forwarding the request.
- Praxis publishes `x-praxis-ai-original-model` and
  `x-praxis-ai-effective-model` as downstream request headers for routing.
- A request with no top-level `model` receives the configured default model.
- Native Responses JSON and SSE traffic pass through without protocol
  translation.
- Codex model discovery (`GET /v1/models`) passes through to the same OpenAI
  cluster.
- Codex retains ownership of its local tools and sends its
  `function_call_output` follow-up through Praxis.
- The OpenAI API key is supplied at runtime and is never written to a manifest,
  log, or committed artifact.

## User Stories

### Stable Client Model Names

An operator gives Codex users a stable model name, `codex-openai-demo`, while
the operator can change the deployed OpenAI model in one Praxis configuration.
Codex does not need to know which upstream model currently serves the request.

### Centralized Routing Evidence

An operator needs to route each request by the model Praxis selected. The demo
uses the effective-model request header in the router and captures the selected
route in Praxis logs. The headers are downstream request metadata; they are not
client response headers.

### Native Codex Tool Use

A developer uses Codex through Praxis to complete a small workspace task.
Codex receives a tool call from the upstream model, executes the tool locally,
returns `function_call_output` through Praxis, and completes the task. Praxis
does not execute commands or own the tool loop.

### Default Model Policy

An integration sends a valid Responses request without a top-level `model`.
Praxis injects the operator-approved default model before forwarding to OpenAI.

## Architecture

```text
+------------------------------+
| Clients                      |
| - Codex CLI                  |
| - curl smoke checks          |
|                              |
| model: codex-openai-demo     |
| Authorization: Bearer <key>  |
+--------------+---------------+
               |
               | POST /v1/responses
               v
+--------------+---------------+
| Praxis                       |
| 127.0.0.1:$PRAXIS_PORT       |
|                              |
| classify -> rewrite -> route |
| effective-model metadata     |
+--------------+---------------+
               |
               | POST /v1/responses
               | model: $OPENAI_MODEL
               v
+------------------------------+
| OpenAI Responses API         |
| api.openai.com:443 (TLS)     |
+------------------------------+
```

## Prerequisites

- **Platform:** Linux or macOS. All scripts use portable Bash and POSIX
  utilities. On macOS, install `envsubst` via `brew install gettext`.
- A Praxis binary built with the `ai-inference` feature, or `PRAXIS_BIN` set
  to one. Build from the [Praxis](https://github.com/praxis-proxy/praxis)
  source:
  ```bash
  git clone https://github.com/praxis-proxy/praxis.git
  cd praxis
  cargo build -p praxis --release --features ai-inference
  export PRAXIS_BIN="$(pwd)/target/release/praxis"
  ```
- Codex CLI installed and authenticated only as required for local operation.
- `curl`, `jq`, Bash, and a current CA bundle.
- An OpenAI project API key with access to the selected `OPENAI_MODEL`.
- Permission to send the test prompts and Codex task to OpenAI.

Use a disposable, scoped project key. Do not use a personal key or place a key
in a shell history, a config file, or an artifact directory.

## Configuration

| Variable | Purpose |
|---|---|
| `OPENAI_API_KEY` | Runtime credential passed from the client through Praxis |
| `OPENAI_MODEL` | Actual OpenAI model name used after rewrite or default injection |
| `PRAXIS_BIN` | Optional absolute path to the Praxis binary |
| `PRAXIS_PORT` | Local listener port; defaults to `18480` |
| `CODEX_CLIENT_MODEL` | Client-facing alias; defaults to `codex-openai-demo` |
| `CODEX_SANDBOX_MODE` | Optional Codex sandbox override; defaults to `workspace-write` |

`OPENAI_API_KEY` is intentionally absent from the rendered Praxis config. The
client supplies it as an HTTP Authorization header and Praxis forwards it to
the upstream API.

## Quick Start

```bash
git clone https://github.com/nerdalert/demos.git
cd demos/demos/openai-responses-codex-passthrough
cp .env.example .env
chmod 600 .env
${EDITOR:-vi} .env
```

## Run The Demo

### All-In-One (Recommended)

Narrated script output:

https://github.com/user-attachments/assets/5caabe9e-7c28-4459-94de-6b443a0cdacd

A single narrated script runs every phase — preflight, Praxis startup, smoke
requests, Codex tool loop, evidence verification, and cleanup:

```bash
./scripts/run-narrative.sh --live
```

On a host where `bwrap` cannot create a `workspace-write` sandbox (containers,
some VMs), use an externally isolated environment and pass both flags:

```bash
CODEX_SANDBOX_MODE=danger-full-access \
  ./scripts/run-narrative.sh --live --allow-danger-full-access
```

Add `--keep-praxis` to leave Praxis running after the demo for further
exploration.

<details>
<summary>Example output</summary>

```text

  Codex CLI -> Praxis -> OpenAI Responses API
  Live interoperability demo (paid API calls)


== 1/5 Preflight ==

✓ bash found
✓ curl found
✓ jq found
✓ envsubst found
▸ Checking Codex CLI
✓ codex found (codex-cli 0.142.0)
✓ Codex CLI flags verified
✓ Codex sandbox mode workspace-write available
▸ Checking Praxis binary
✓ Praxis binary found
▸ Checking environment variables
✓ OPENAI_API_KEY is set (value hidden)
✓ OPENAI_MODEL=gpt-5.5
▸ Checking port 18480
✓ Port 18480 is available
✓ All prerequisites satisfied

== 2/5 Start Praxis ==

▸ Starting Praxis in the background on 127.0.0.1:18480
✓ Praxis is listening on port 18480

== 3/5 Responses Smoke Checks ==

Four live requests prove the Praxis filter pipeline:

  1. Aliased model    - client sends the demo alias; Praxis rewrites it
  2. Default injection - no model field; Praxis injects the configured default
  3. SSE streaming     - chunked Responses stream forwarded through the proxy
  4. Direct control    - same key hits OpenAI directly to confirm baseline

▸ 1. Aliased model request (codex-openai-demo → gpt-5.5)
✓ 1. Aliased model request (codex-openai-demo → gpt-5.5): HTTP 200
▸ 2. Default model injection (no model field)
✓ 2. Default model injection (no model field): HTTP 200
▸ 3. Streaming SSE request through Praxis
✓ 3. Streaming SSE request through Praxis: HTTP 200
▸ 4. Direct OpenAI control request (no Praxis)
✓ 4. Direct OpenAI control request (no Praxis): HTTP 200
✓ All smoke requests completed. Evidence saved under artifacts/

== 4/5 Codex Tool Loop ==

Codex CLI uses Praxis as a custom Responses provider:

  - wire_api = responses, base URL = Praxis loopback
  - Client model is the demo alias; Praxis rewrites before forwarding
  - Codex owns tool execution locally and returns function_call_output
  - Task: create proof.txt with exact content, read it back

▸ WARNING: sandbox mode overridden to danger-full-access by CODEX_SANDBOX_MODE
▸ Codex workspace: artifacts/codex-workspace
▸ Custom provider → http://127.0.0.1:18480 (wire_api=responses)
▸ Client model: codex-openai-demo
✓ Codex completed successfully
✓ Proof file verified: artifacts/codex-workspace/proof.txt
▸ JSONL log: artifacts/codex.jsonl (8 lines)
▸ Stderr log: artifacts/codex.stderr.log

== 5/5 Evidence Verification ==

▸ Verifying smoke-responses evidence
✓ Alias response file exists
✓ Alias response is valid JSON
✓ Default-injection response file exists
✓ Default-injection response is valid JSON
▸ Verifying SSE capture
✓ SSE capture file exists
✓ SSE capture contains data: events
✓ SSE capture contains terminal completion event
▸ Verifying Praxis logs
✓ Praxis log contains route match for openai cluster
▸ Verifying Codex evidence
✓ Codex JSONL output exists
✓ Codex JSONL has content (lines > 0)
✓ Codex proof file exists
✓ Codex proof file has exact expected content
▸ Checking artifacts for leaked credentials
✓ No API key patterns found in artifacts

✓ All evidence checks passed

  Demo complete. Captured evidence:

    - Alias and default-injection JSON requests completed (HTTP 200)
    - SSE stream contains data: events and response.completed
    - Praxis logs show effective-model route selection to OpenAI cluster
    - Codex JSONL session log produced
    - Proof file contains exact expected content
    - No API key patterns found in artifacts

▸ Stopping Praxis
✓ Praxis stopped
```

</details>

### Step-By-Step (Multi-Terminal)

For presentation or debugging, each phase can be run independently.

First validate the local environment:

```bash
./scripts/check-prereqs.sh
```

Start Praxis in one terminal. It renders a runtime configuration under
`artifacts/` and keeps the proxy in the foreground:

```bash
./scripts/start-praxis.sh
```

In another terminal, run the request-level checks:

```bash
./scripts/smoke-responses.sh
```

The smoke script captures four live requests:

1. An aliased JSON response request.
2. A request without `model`, demonstrating default injection.
3. A streaming SSE response request.
4. A direct OpenAI control request, used only to confirm the key and model
   work outside Praxis.

Then run Codex through Praxis:

```bash
./scripts/run-codex.sh
```

Codex runs in a dedicated demo workspace and is asked to create
`proof.txt` containing `praxis-openai-codex-e2e`. The script configures
Codex with a custom Responses provider whose base URL is Praxis, not OpenAI.

On a host where bwrap cannot create a `workspace-write` sandbox, run the
Codex step only inside an externally isolated environment with:

```bash
CODEX_SANDBOX_MODE=danger-full-access ./scripts/run-codex.sh
```

This override disables Codex sandboxing. It is not the default and should not
be used on a developer workstation or shared host.

Verify the captured evidence after both runs finish:

```bash
./scripts/verify-evidence.sh
```

## Expected Evidence

The verifier checks the structural facts that are stable across real model
output:

- The aliased client model and a request with no model both complete through
  Praxis, proving model rewrite and default injection before OpenAI receives
  the request.
- Praxis logs show a route selected by the effective-model request header.
- The streaming capture contains valid Responses SSE events and a terminal
  completion event.
- Codex exited successfully and produced JSONL output.
- The Codex workspace contains the expected proof file.

The demo does not compare generated text or SSE bytes with a direct OpenAI
request. Real inference output is nondeterministic.

## Files

| File | Purpose |
|---|---|
| `.env.example` | Documented runtime variables with no secrets |
| `praxis.yaml.tmpl` | Praxis configuration template for the live OpenAI upstream |
| `scripts/run-narrative.sh` | All-in-one narrated runner for the full live demo |
| `scripts/check-prereqs.sh` | Validates tools, variables, and local safety prerequisites |
| `scripts/start-praxis.sh` | Renders the runtime config and starts Praxis in the foreground |
| `scripts/smoke-responses.sh` | Sends alias, default-injection, SSE, and direct-control requests |
| `scripts/run-codex.sh` | Runs the manual Codex CLI tool-loop demonstration |
| `scripts/verify-evidence.sh` | Validates routing logs, response captures, SSE, JSONL, and proof file |
| `scripts/stop-praxis.sh` | Stops only the Praxis process started by this demo |
| `artifacts/` | Ignored runtime configs, logs, request captures, and Codex workspace |

## Operational Notes

- This demo exercises pass-through authentication. A production shared gateway
  should normally authenticate callers to Praxis and inject a separate
  upstream key there.
- The filter rewrites only the top-level request `model` field. It does not
  translate Responses traffic into Chat Completions or normalize upstream
  responses.
- Codex tool use depends on the selected upstream model producing compatible
  Responses function-call events. Praxis preserves those events; it does not
  manufacture them.
- The OpenAI `Host` header is set in this demo's Praxis configuration because
  OpenAI's Cloudflare edge rejects the local listener host. Praxis preserves
  the client Host by default for general reverse-proxy use cases.
- Model rewrite buffers and re-serializes JSON requests up to its configured
  body limit. SSE responses remain streamed.
- Live API latency and cost include OpenAI inference and network time. Do not
  use this demo as a proxy-only performance benchmark.

## Cleanup

Use the demo cleanup script to stop the local Praxis process it owns:

```bash
./scripts/stop-praxis.sh
```

The scripts must never kill unrelated processes, print credentials, or commit
generated artifacts.
