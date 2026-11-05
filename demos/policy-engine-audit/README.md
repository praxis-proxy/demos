# Praxis Policy Engine audit demo: agent tool calls, provably on record

The [policy-engine](../policy-engine/) demo shows Praxis deciding who may
call which tool, what comes back and where it may go next. This demo adds
the audit half of that story: every ruling the gateway makes leaves as a
signed, hash-chained OCSF record through the
[`ocsf-audit`](https://github.com/praxis-proxy/policy/tree/main/reference/plugins/ocsf-audit)
sink, and an independent append-only ledger, Jonathan Kershaw's
[ARE](https://github.com/jkershawrh/are-immutable-ledger), receipts each one
so an auditor can prove what happened without trusting the gateway.

```text
HR copilot agent / curl
    │  MCP tools/call, Keycloak tokens
    ▼
Praxis gateway (:8090)            praxis-proxy 0.7.4 + PPE policy filter
    │  ├─ identity (Keycloak JWT), APL policy, CEL, session taint (Valkey),
    │  │  RFC 8693 token exchange, SSN redaction, PII scan
    │  └─ ocsf-audit sink ── stderr: one OCSF 6003 record per ruling,
    │                         hash-chained and DSSE-signed (AID-EMIT-1)
    ▼                                     │
HR MCP server (:9100)                     ▼
                         adapters/cpex/cpex_to_ledger.py
                                          │  one receipt per record
                                          ▼
                                 ARE ledger (gRPC :19292) ── PostgreSQL
```

Same HR copilot, same personas and tools as the policy-engine demo. What
is new is that every receipt comes from a record the gateway itself wrote
and signed, and a second system keeps the chain.

## Who built what

This demo is a joint effort across three projects, and the credit splits
the same way:

- **The ARE immutable ledger and its proof layer** (hash-chained storage,
  proof receipts, the proof explorer, the compose stack the demo starts)
  were started and are maintained by Jonathan Kershaw. The canonical
  repository is
  [jkershawrh/are-immutable-ledger](https://github.com/jkershawrh/are-immutable-ledger);
  `tools/fetch-ledger.sh` pins one commit of it.
- **The Praxis policy engine, its executor audit seam and the enforcement
  shown here** (identity, APL policy, CEL, session taint, token exchange,
  redaction) are the Praxis team's work, in particular Frederico Araujo
  and Teryl Taylor ([praxis-proxy/policy](https://github.com/praxis-proxy/policy)).
- **The `ocsf-audit` sink, the AID-EMIT-1 alignment of the ledger's CPEX
  adapter, and this demo** (gateway host, scenarios, chat walkthrough,
  recorder) were built by Jeff Leva, with Kersh, Fred and Teryl reviewing.

The integration discussions that led here were started by Jonathan Kershaw
with the Praxis team; this directory is their outcome, not a separate
project.

## Watch it run

An LLM-driven session in front of the gateway, driven through
[agent/chat.py](agent/chat.py) with the records pane beside it: Bob's allowed
lookup with its four signed records, Alice denied before the HR system sees
the request, Bob's outbound email refused by session taint, and Eve's SSN
redacted in flight. Each ruling lands in the records pane as a signed, chained
OCSF record the moment it is made, with the denials in red.

<!-- Recorded with tools/record-live.sh (see agent/demo/README.md); to replace
     it, record again and `asciinema upload agent/demo/chat-live.cast`. -->
[![Praxis Policy Engine audit demo recording](https://asciinema.org/a/CIdfHzlDLCswA0SN.svg)](https://asciinema.org/a/CIdfHzlDLCswA0SN)

## Run it

```bash
./run-demo.sh               # business story, scenarios 01-04
./run-demo.sh --deep-dive   # record fields shown, plus 05 and 06
```

No time to run it? [SAMPLE-RUN.md](SAMPLE-RUN.md) is a full `--deep-dive`
transcript.

Presenting it? [agent/CHAT.md](agent/CHAT.md) runs the same beats as a live
conversation: `agent/chat.py` is an LLM agent whose every tool call goes
through the gateway, and `tools/watch-records.sh` shows each verdict land as
a signed record in a second pane.

Needs Docker, git, a Rust toolchain (1.92+), `jq`, `openssl`, and Python
3.10+ with `grpcio` and `protobuf` installed (`tools/fetch-ledger.sh`, then
`pip install -r .ledger/adapters/cpex/requirements.txt`). The first run
checks out the ledger at a pinned commit into `.ledger/`, builds its image
and the gateway, which takes several minutes. The gateway runs on the host,
not in Compose, so Keycloak's `localhost` issuer matches and the restart
beat can `kill -9` a real process. Praxis refuses to run as root.

## The story, scenario by scenario

Each scenario opens with who is acting, what the policy says and what risk it
avoids, and closes with what the auditor gets.

| # | Scenario | Business framing | What the auditor gets |
|---|---|---|---|
| 01 | HR reads compensation | Bob (HR) reads a salary through the agent; the call goes out on a scoped token | Four chained, signed OCSF records (identity, token exchange, authorize, response) and a verified ledger receipt |
| 02 | Engineer denied | Alice (engineering) tries the same; `require(role.hr)` refuses | A signed deny naming the principal, the tool and the policy line (`status_code`) |
| 03 | **Prompt injection blocked** | A wiki page tells Bob's agent to email the salary record to `payroll-audit@evil.test`; the agent obeys; the gateway refuses because the session read secret data | The doc read, the salary read and the refused exfiltration as one chain, with `session_tainted_secret` inside the signed bytes; the HR system sent nothing |
| 04 | SSN redacted | Eve (HR, no `view_ssn`) asks for the SSN and gets `[REDACTED]` | Allow-after-modify with differing `aid.content` digests, and the SSN nowhere in the audit trail |
| 05 | Crash and restart *(deep dive)* | `kill -9` the gateway mid-shift | A new epoch with `stream_seq` back at 0; the adapter reports `EPOCH CHANGE`, not a gap |
| 06 | Tamper and loss *(deep dive)* | Flip one deny to allow; delete one record | The AID-EMIT-1 validator, with only the public key, flags the edit (fingerprint, signature, broken link) and the deletion (stream gap) |

Scenario 03 is the headline. The agent ([agent/agent.py](agent/agent.py))
is deliberately naive: it treats an `AGENT INSTRUCTION` comment in tool
output as a task. Two independent rules stop it
([config/policy.yaml](config/policy.yaml)): the session is tainted `secret`
once it reads compensation, and email may only go to `@corp.com`. The taint
rule fires first; the domain rule catches the same email from a clean session.

## What is in this directory

| Path | What it is |
|---|---|
| `gateway/` | The Praxis host: stock `praxis-proxy` 0.7.4 plus host-registered `audit/ocsf` and `validator/pii-scan` factories, and `mcp_classify` |
| `config/praxis.yaml` | Listener, filter chain, upstream |
| `config/policy.yaml` | The PPE policy (adapted from the praxis-demos HR policy) with the `ocsf-audit` sink |
| `hr-mcp-server/` | The HR MCP server from the policy-engine demo plus `fetch_doc` (the injected page) and `GET /sent` |
| `keycloak/` | The `cpex-demo` realm (bob, alice, eve, charlie) |
| `agent/agent.py` | The scripted agent for scenario 03 |
| `agent/chat.py` | The live LLM agent for presenting (vendored from praxis-proxy/demos), with [CHAT.md](agent/CHAT.md) |
| `agent/demo/` | The tmux + asciinema recorder for the chat demo, with [its README](agent/demo/README.md) |
| `scenarios/` | 01-06 and their shared helpers |
| `tools/` | Gateway start/stop, ledger receipt lookup, pinned ledger and validator fetches, live record watcher |

`out/` (records, logs), `keys/` (the generated signing key) and `.ledger/`
(the pinned ledger checkout: image source, migrations, CPEX adapter, proof
explorer) are git-ignored. The gateway binary, the signing key id and the
records' `authority_uid` still call themselves `praxis-audit`, the demo's
name in the ledger repository where it was first built.

## Querying the records

The records are plain OCSF, so any SIEM or `jq` reads them:

```bash
# every denial, with who, what and why
grep '^{' out/gateway.stderr | jq -c 'select(.action=="Denied")
  | {who: .actor.user.uid, roles: .actor.roles, tool: .tool.name, why: .status_code}'

# every ruling that changed a payload
grep '^{' out/gateway.stderr | jq -c 'select(.unmapped."aid.content".input_hash
  != .unmapped."aid.content".output_hash) | {tool: .tool.name, steps: .unmapped."aid.decision".steps}'
```

## Known issues and upstream asks

Found while wiring the merged sink into a real Praxis host. Each is worked
around here; the first needs an upstream fix.

1. **The sink could not load beside any route.** Under `dispatch: policy`
   (the default) the APL visitor rejected a hookless audit sink as "no step
   names `ocsf-audit`, so it can never run", and naming it in `run()` denied
   every request. Fixed upstream in
   [praxis-proxy/policy#210](https://github.com/praxis-proxy/policy/pull/210),
   which landed on the policy 0.5.0 line. Praxis 0.7.x depends on
   praxis-policy 0.4.1, and a `[patch.crates-io]` entry must match that
   version, so `gateway/Cargo.toml` keeps the fix's 0.4.x commit on the
   author's fork until a Praxis release depends on praxis-policy 0.5.x
   (see the comment in that file). The repin is then a version bump, not a
   code change.
2. **No keyed content digests through Praxis.** Praxis 0.7.4 registers no
   secret provider backends with the engine it builds, so
   `content_provenance_key` cannot name a secret. The demo uses `unkeyed`
   (plain SHA-256), which the engine warns about at every load.
3. **`read_subject` alone gives an empty actor.** The plugin README lists five
   capabilities; `actor.roles` and `actor.user.groups` also need
   `read_roles` and `read_teams`.
4. **The MCP classifier is a stand-in.** Praxis's policy filter needs
   `mcp.method` from the `mcp` filter in praxis-proxy/ai, which is not
   published. `gateway/src/mcp_classify.rs` sets the two keys and nothing
   else.
5. **Sample output is v0.5 behavior.** Argument rendering, per-sink streams
   and stream ids change when the audit serialization split lands (R5, R7,
   R24 in the requirements). The validator is pinned to AID-EMIT-1
   1.2.0-draft (`abc7bd8`), as praxis-proxy/policy cites it.

AuthBridge and multi-hop scenarios are out of scope for this version.

## Where the pieces come from

The ledger side (`Dockerfile`, migrations, the CPEX adapter that turns
records into receipts, the proof explorer that verifies chains) is not
copied here. `tools/fetch-ledger.sh` checks the ledger repository out at one
pinned commit into `.ledger/`, and the compose file and scenarios use that
checkout, so the image, the schema and the adapter always match. The
canonical ledger is
[jkershawrh/are-immutable-ledger](https://github.com/jkershawrh/are-immutable-ledger),
and the pin is its v0.2.0 commit, which carries the demo's adapter changes.
The pin is a commit rather than a tag so a moved tag cannot change what the
demo builds. The demo was
first built in that repository, as `demo/praxis-audit`, where the earlier
simulated-receipt version (`demo/joint-cpex`) also lives.
`agent/chat.py` is the policy-engine demo's chat client with three small
changes listed at the top of the file.
