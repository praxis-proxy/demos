# CPEX HR Demo

End-to-end demo of **Praxis** with the feature-gated **`cpex`** filter,
**Keycloak** as the OIDC IdP, and a mock **MCP server**. It exercises the full
CPEX/APL (Authorization Policy Logic) stack:

- multi-source identity (user, agent, and workload JWTs in separate headers,
  each validated by its own identity plugin)
- RFC 8693 token exchange (Keycloak Standard Token Exchange v2)
- policy requirements (`require(role.hr)`, `require(team.engineering)`)
- a policy decision point for relationship-based authorization (Cedar or CEL)
- on-the-wire body rewriting (`redact(args.ssn)`; the upstream never sees the value)
- PII scanning on tool arguments
- structured audit emission
- session taint (cross-tool, cross-request data-flow control)

## The story

Three personas carry it:

| Persona | Identity | Result |
|---|---|---|
| Bob | HR, `view_ssn` | Full compensation record, SSN included |
| Eve | HR, no `view_ssn` | Same record, SSN redacted |
| Alice | Engineering | Denied HR tools; allowed internal repos, denied external |

Bob and Eve send the byte-for-byte same `get_compensation` request and the
backend returns the same record, but Eve's response comes back without the SSN
because the policy redacts it. Bob's request reaches the backend with a freshly
minted, audience-scoped token, never his original IdP JWT.

## What runs where

```text
+------------------------------------------------------------------+
| host                                                             |
|                                                                  |
|   praxis (--features cpex)   :8090                               |
|     filter: mcp            parse JSON-RPC, set mcp.method/name    |
|     filter: cpex           identity + APL + PDP + delegation +    |
|                            PII + audit + taint + body rewrite     |
|     filter: router         forward / to the hr-mcp upstream       |
|     filter: load_balancer  single-endpoint cluster                |
+------------------------------------------------------------------+
        ^                                  v
  chat / curl                       hr-mcp-server (Python, docker)
  Authorization + X-User-Token      :9100, receives the rewritten
  (+ X-Session-Id)                  request with the minted token

+------------------------------------------------------------------+
| docker compose                                                   |
|   keycloak   cpex-demo realm: bob/alice/eve users; praxis-gateway |
|              / workday-api / github-api clients; STE v2           |
|   hr-mcp     mock MCP server: get_compensation, send_email,       |
|              search_repos                                         |
+------------------------------------------------------------------+
```

## Prerequisites

- Docker daemon running (Docker Desktop, Rancher Desktop, or Colima)
- Rust toolchain (whatever praxis's `rust-version` requires)
- Ports `8081`, `8090`, `9100` free on localhost

## Quick start

`restart.sh` builds praxis if needed, brings up a clean Keycloak and MCP backend,
starts the gateway, and smoke-tests scenario 01. The whole demo is one command:

```bash
# From this directory. First run builds praxis (~5 min cold, ~30s warm).
./restart.sh
./walkthrough.sh
```

The equivalent steps, spelled out:

```bash
GATEWAY_BIN="$(./build-praxis.sh)"   # build the cpex gateway, print its path
docker compose up -d                 # Keycloak + mock MCP server
./verify-token-exchange.sh           # wait for the realm import, check STE v2
"$GATEWAY_BIN" -c ./praxis.yaml &     # start the gateway
./walkthrough.sh                     # narrated tour of the core scenarios
```

## Configuring the praxis source

Praxis is not vendored here. `build-praxis.sh` resolves where to get it (first
match wins):

| Env var | Effect |
|---|---|
| `PRAXIS_BIN` | Path to an already-built praxis binary. Used as-is, no build. |
| `PRAXIS_DIR` | Path to a praxis checkout. Built in place with `--features cpex`. |
| `PRAXIS_GIT_URL` (+ `PRAXIS_GIT_REF`) | Clone this URL at the given branch, tag, or commit into `PRAXIS_SRC` (default `.praxis-src/`), then build. |
| default | A sibling `../../../praxis` checkout if present, otherwise clone the public repo at `PRAXIS_GIT_REF` (default `main`). |

```bash
# Build a specific upstream commit from git:
PRAXIS_GIT_URL=https://github.com/praxis-proxy/praxis.git \
PRAXIS_GIT_REF=feat/cpex \
./restart.sh

# Or point at a local checkout or a prebuilt binary:
PRAXIS_DIR=~/src/praxis ./restart.sh
PRAXIS_BIN=~/src/praxis/target/release/praxis ./restart.sh
```

## Scenarios

Nine scenarios cover every feature in the filter. Run any one directly, for
example `./scenarios/01-bob-allow.sh`.

| # | Scenario | Demonstrates |
|---|----------|---|
| 01 | Bob (HR + `view_ssn`) calls `get_compensation` | Identity, APL, RFC 8693 delegation, full record returned |
| 02 | Alice (engineer) calls `get_compensation` | APL `require(role.hr)` deny, JSON-RPC error envelope |
| 03 | Eve (HR, no `view_ssn`) calls `get_compensation` | `redact(args.ssn)` rewrites the body; the tool never sees the SSN |
| 04 | Alice calls `search_repos` for an internal repo | PDP permit (Cedar, or CEL) |
| 05 | Alice calls `search_repos` for an external repo | PDP deny (Cedar `cedar.default_deny`, CEL `cel.policy_denied`) |
| 06 | Bob (HR) calls `search_repos` | APL deny on team membership; the PDP never runs |
| 07 | Bob sends an email with an SSN in the body | PII scanner denies; audit-log still records the attempt |
| 08 | Bob calls `get_compensation` then `send_email` in one session | Session taint: the later email is denied (`session_tainted_secret`) even with a clean body |
| 09 | Eve taints a session id, Bob reuses the same id | Cross-principal isolation: Bob's reuse is a different bucket and is allowed |

## Alternative: CEL instead of Cedar

Scenarios 04 and 05 gate `search_repos` through a policy decision point. The
default config (`cpex.yaml`) uses Cedar. An alternate config (`cpex-cel.yaml`)
expresses the same decision with CEL (Common Expression Language):

```bash
GATEWAY_CONFIG=praxis-cel.yaml ./restart.sh
./scenarios/04-alice-internal-allow.sh        # 200 allow
./scenarios/05-alice-external-cedar-deny.sh   # -32001 deny, violation cel.policy_denied
```

The backends differ in how the rule is authored, not in the outcome:

| | Cedar (`cpex.yaml`) | CEL (`cpex-cel.yaml`) |
|---|---|---|
| Where the rule lives | `policy_text` block (Cedar policy set) | inline `cel: { expr }` on the route |
| The rule | `permit(...) when { principal.roles.contains("engineer") && resource.visibility == "internal" }` | `(has(role.engineer) && role.engineer && args.visibility == "internal") \|\| (has(role.security) && role.security)` |
| Deny reaction | implicit `cedar.default_deny` | `on_deny: [deny('reason', 'cel.policy_denied')]` (a bare default-deny works too) |
| Deny violation code | `cedar.default_deny` | `cel.policy_denied` |
| Best for | versioned or signed policy sets, entity and relationship model | self-contained boolean predicate, no external policy store |

Both PDP backends are compiled into the same binary. The config's
`pdp: { kind: ... }` and the route's `cedar:` or `cel:` step select which one
runs. The CEL step also shows an `on_deny:` reaction attaching a human reason and
a stable violation code; `on_deny` and `on_allow` work on any PDP step.

## Session taint (scenarios 08 and 09)

`get_compensation` runs `taint(secret, session)`, attaching the label `secret` to
the session. `send_email` then refuses to send when the session carries it:

```yaml
# get_compensation
- "taint(secret, session)"

# send_email
- "security.labels contains \"secret\": deny('external email blocked', 'session_tainted_secret')"
```

The produce-then-consume spans two separate tool calls:

1. Produce. `taint(secret, session)` records the label. cpex persists it to the
   session store when the request ends.
2. Persist and scope. The store is keyed by `H(subject : session_id)`. The
   session id comes from the `X-Session-Id` header, which the praxis `cpex`
   filter maps to `agent.session_id`. cpex binds it to the resolved subject, so
   the same id under a different user is a different bucket.
3. Consume. On the next request in that session the stored label is hydrated into
   `security.labels`, and the `send_email` predicate reads it to deny.

```bash
./scenarios/08-bob-taint-deny.sh                   # S3 denied, session_tainted_secret
./scenarios/09-cross-principal-taint-isolation.sh  # S3 allowed, subject-scoped
```

The deny in 08 fires even when the email body is clean. The session is tainted,
not the content, which is what separates it from scenario 07's content-based PII
deny. Scenario 09 shows the taint cannot cross principals.

Tainting is independent of the PDP, so 08 and 09 behave the same under both
`cpex.yaml` and `cpex-cel.yaml`. The session store is in-memory and per process:
taint resets when the gateway restarts, and the scenarios use fresh per-run
session ids so reruns start clean.

## Notes

**Step ordering (scenario 07).** Policy steps run in order, and a deny
short-circuits the rest of the chain. The `send_email` route lists
`run(audit-log)` before `run(pii-scan)` so the attempt is recorded before the PII
gate blocks it. `audit-log` only observes, so running it first never changes the
verdict. `run(...)` is an alias for `plugin(...)`.

**Response body length.** Scenario 03's redaction pads a shorter rewritten body
with trailing spaces to match the committed Content-Length. JSON parsers ignore
the padding, so the wire stays correct. This is documented in the filter source.

## Files

| File or directory | Purpose |
|---|---|
| `praxis.yaml` | Praxis listener and filter chain (`mcp` -> `cpex` -> `router` -> `load_balancer`); loads `cpex.yaml` |
| `cpex.yaml` | CPEX policy: plugins, routes, Cedar PDP policy text |
| `praxis-cel.yaml` | Same listener as `praxis.yaml`, loads `cpex-cel.yaml`. Run via `GATEWAY_CONFIG=praxis-cel.yaml` |
| `cpex-cel.yaml` | CEL variant: `search_repos` uses an inline `cel:` expression, no `apl:` wrapper |
| `docker-compose.yml` | Keycloak (8081) and hr-mcp (9100) |
| `keycloak/realm-export.json` | Realm with users, clients, and STE v2 |
| `hr-mcp-server/` | Python mock MCP server (Dockerfile and `server.py`) |
| `scenarios/*.sh` | The nine scenarios (including 08 and 09 session taint) and `_lib.sh` helpers |
| `mint-token.sh` | Mint a user or client token via Keycloak |
| `verify-token-exchange.sh` | Check that STE v2 is configured correctly |
| `walkthrough.sh` | Narrated tour of the core scenarios |
| `restart.sh` | Tear down, bring up, and smoke-test the demo |
| `build-praxis.sh` | Resolve and build the praxis-cpex gateway (see "Configuring the praxis source") |
| `agent/` | Optional Python chat agent for an LLM-driven demo |

## Where the filter lives

The `cpex` filter source is in the praxis repository at
[`filter/src/builtins/http/security/cpex/`](https://github.com/praxis-proxy/praxis/tree/main/filter/src/builtins/http/security/cpex),
behind the `cpex` Cargo feature on `praxis-proxy-filter`. That feature registers
both the Cedar (`apl-pdp-cedar-direct`) and CEL (`apl-pdp-cel`) PDP backends, so
one binary serves both `cpex.yaml` and `cpex-cel.yaml`. See the filter's own
README there for configuration and internals.
```
