# CPEX HR Demo

End-to-end demo wiring **Praxis** (this proxy) with the
feature-gated **`cpex`** filter, **Keycloak** (OIDC IdP), and a mock
**MCP server** to exercise the full CPEX/APL plugin stack:

* multi-source identity (user + agent + workload JWTs in different
  headers, validated by separate identity plugins)
* RFC 8693 OAuth 2.0 token exchange (Keycloak Standard Token
  Exchange v2)
* attribute-based policy in APL (`require(role.hr)`,
  `require(team.engineering)`, …)
* Cedar PDP for relationship-based authorization
* on-the-wire body rewriting (`redact(args.ssn)` — the upstream
  literally never sees the value)
* PII scanning on tool arguments
* structured audit emission

> The story: Alice (an engineer) is denied. Bob (HR) is allowed and
> his request reaches the backend with a freshly-minted,
> audience-scoped token — **never** his original IdP JWT. Eve (HR
> without `view_ssn`) is allowed, but `args.ssn` is rewritten to
> `[REDACTED]` before the backend ever sees it.

## What runs where

```
┌──────────────────────────────────────────────────────────────────┐
│ host                                                             │
│                                                                  │
│   praxis (built from this fork, --features cpex)    :8090        │
│        │                                                         │
│        ├── filter: mcp        (parses JSON-RPC, stashes          │
│        │                       mcp.method / mcp.name in metadata)│
│        ├── filter: cpex       (identity + APL + delegation +     │
│        │                       PII + audit + body rewrite)       │
│        ├── filter: router     (forwards / to hr-mcp upstream)    │
│        └── filter: load_balancer (single endpoint cluster)       │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
            ▲                                  ▼
    chat / curl                       hr-mcp-server (Python, docker)
    (X-User-Token + Authorization)    :9100 — mock HR MCP server
                                      Receives the gateway-rewritten
                                      request with the audience-scoped
                                      token.

┌──────────────────────────────────────────────────────────────────┐
│ docker compose                                                   │
│   • keycloak     (cpex-demo realm with bob/alice/eve users +     │
│                   praxis-gateway / workday-api / github-api      │
│                   clients; STE v2 enabled)                       │
│   • hr-mcp       (Python mock MCP server with get_compensation,  │
│                   send_email, list_employees tools)              │
└──────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Docker daemon running (Docker Desktop / Rancher Desktop / Colima)
- Rust toolchain (whatever praxis's `rust-version` requires)
- Ports `8081`, `8090`, `9100` free on localhost

## Quick start

`restart.sh` builds praxis if needed (via `build-praxis.sh`), brings up
a clean Keycloak + MCP backend, starts the gateway, and smoke-tests
scenario 01 — so the whole demo is one command:

```bash
# From this directory. First run builds praxis (~5 min cold; ~30s warm).
./restart.sh
./walkthrough.sh
```

Prefer the steps spelled out? They're equivalent:

```bash
# 1. Build the gateway with the cpex feature (resolves the praxis source
#    per "Configuring the praxis source" below; prints the binary path).
GATEWAY_BIN="$(./build-praxis.sh)"

# 2. Bring up Keycloak + the mock MCP server.
docker compose up -d

# 3. Wait for Keycloak to import its realm (30-60s on first start).
./verify-token-exchange.sh

# 4. Start the gateway pointing at the demo's praxis.yaml config.
"$GATEWAY_BIN" -c ./praxis.yaml &

# 5. Run the narrated walkthrough.
./walkthrough.sh
```

## Configuring the praxis source

Praxis is **not** vendored in this repo — `build-praxis.sh` decides where
to get it from (first match wins):

| Env var | Effect |
|---|---|
| `PRAXIS_BIN` | Path to an already-built praxis binary; used as-is (no build). |
| `PRAXIS_DIR` | Path to a praxis checkout; built in place with `--features cpex`. |
| `PRAXIS_GIT_URL` (+ `PRAXIS_GIT_REF`) | Clone this URL at the given branch/tag/commit into `PRAXIS_SRC` (default `.praxis-src/`), then build. |
| _(default)_ | A sibling `../../../praxis` checkout if present; otherwise clone the public repo at `PRAXIS_GIT_REF` (default `main`). |

```bash
# Build a specific upstream commit from git:
PRAXIS_GIT_URL=https://github.com/praxis-proxy/praxis.git \
PRAXIS_GIT_REF=feat/cpex \
./restart.sh

# Or point at a local checkout / prebuilt binary:
PRAXIS_DIR=~/src/praxis ./restart.sh
PRAXIS_BIN=~/src/praxis/target/release/praxis ./restart.sh
```

## What the walkthrough demonstrates

Seven scenarios cover every feature in the filter:

| # | Scenario | Demonstrates |
|---|----------|---|
| 01 | Bob (HR + `view_ssn`) → `get_compensation` | Identity + APL + RFC 8693 delegation + full record returned |
| 02 | Alice (engineer) → `get_compensation` | APL `require(role.hr)` fast-path deny, JSON-RPC error envelope |
| 03 | Eve (HR but no `view_ssn`) → `get_compensation` | APL `redact(args.ssn)` rewrites the upstream body — tool literally never sees the SSN |
| 04 | Alice (engineering) → `search_repos` for internal repos | Cedar PDP permit |
| 05 | Alice (engineering) → `search_repos` for external repos | Cedar PDP default-deny |
| 06 | Bob (HR) → `search_repos` (any) | APL fast-path deny — Cedar never runs |
| 07 | Bob (HR) → `send_email` with SSN in the body | PII scanner plugin denies + audit-log plugin still emits |

Run any one directly: `./scenarios/01-bob-allow.sh`.

## Files

| File / dir | Purpose |
|---|---|
| `praxis.yaml` | Praxis listener + filter chain (`mcp` → `cpex` → `router` → `load_balancer`) |
| `cpex.yaml` | CPEX policy document — plugins + routes + Cedar policy text |
| `docker-compose.yml` | Keycloak (8081) + hr-mcp (9100) |
| `keycloak/realm-export.json` | Pre-configured realm with users + clients + STE v2 |
| `hr-mcp-server/` | Python mock MCP server (Dockerfile + `server.py`) |
| `scenarios/*.sh` | The 7 scenarios + `_lib.sh` shared helpers |
| `mint-token.sh` | Helper: mint a user/client token via Keycloak password grant |
| `verify-token-exchange.sh` | Smoke test: STE v2 is configured correctly |
| `walkthrough.sh` | Narrated tour through all 7 scenarios |
| `restart.sh` | One-shot: tear down, bring up, smoke-test the demo |
| `build-praxis.sh` | Resolves + builds the praxis-cpex gateway (see "Configuring the praxis source") |
| `agent/` | Optional Python chat agent (uses watsonx) for an LLM-driven demo |

## Where the filter lives

The `cpex` filter source lives in the praxis repository at
[`filter/src/builtins/http/security/cpex/`](https://github.com/praxis-proxy/praxis/tree/main/filter/src/builtins/http/security/cpex),
behind the `cpex` Cargo feature on `praxis-proxy-filter` (and forwarded
by `praxis` via the workspace feature of the same name).

## Note on plugin ordering (scenario 07)

Policy steps run in order, and a step that **denies short-circuits
the rest of the chain** — anything listed after a deny never runs.
That is why the `send_email` route lists `plugin(audit-log)` *before*
`plugin(pii-scan)` (see `cpex.yaml`): the audit observation has to
fire before the PII gate blocks the call, otherwise the denied
attempt would leave no audit trail. `audit-log` is observation-only —
it cannot allow or deny — so ordering it first never changes the
verdict; it only guarantees the record is emitted. Scenario 07 prints
that emitted record inline so you can see the denied attempt on the
trail (the SSN-bearing body and all).

## Note on the body-rewrite workaround

Scenario 03 (`redact(args.ssn)`) uses a "pad with trailing spaces"
workaround when the rewritten body is shorter than the original,
because the praxis filter API doesn't currently expose
Content-Length recompute from the body phase. JSON parsers ignore
the trailing whitespace, so wire correctness is preserved — but it's
a workaround rather than an architectural answer. Documented in the
filter source.
