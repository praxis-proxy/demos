# HR Copilot — Manager-Approval (Human-in-the-Loop) Demo

This builds on the base [CPEX HR demo](README.md) and adds a **manager
approval** step: when Bob asks the agent for a sensitive change (a large
raise), the gateway suspends the action and pushes an out-of-band approval
to his manager (Alice) over **OIDC CIBA**. The agent doesn't block — it
tells Bob it's pending and keeps helping with other things. The moment
Alice approves on her "phone," the agent **cuts back in** and completes the
task.

Nothing in the agent's code knows about approvals as a protocol — the
gateway orchestrates it; the agent just sees a "retry later" and a result.

## What's added on top of the base demo

| Component | Role | Where |
|---|---|---|
| `adjust_compensation` tool | the sensitive action (a raise) | `hr-mcp-server/server.py` |
| `require_approval(...)` route | suspends adjustments over $10k | `cpex.yaml` |
| `manager-approver` plugin | drives CIBA against Keycloak | `cpex.yaml` (`kind: elicitation/ciba`) |
| Keycloak CIBA + `manager` claim | Bob's manager = Alice | `keycloak/realm-export.json` |
| **auth-channel** (web approval UI) | Alice's "phone" — Approve/Deny | `auth-channel/` → `http://localhost:5001` |
| Background poller in the agent | re-checks the approval, cuts in | `agent/chat.py` |

## Architecture

```
 Bob ── chat ──► agent (chat.py) ── tools/call ──► Praxis-CPEX gateway ──► HR MCP server
                    ▲  │ -32120 "pending, retry with id"      │ require_approval
                    │  │                                       ▼
              🔔 cut-in                              Keycloak (CIBA) ──► auth-channel UI ──► Alice
              (poller re-checks                                                    (Approve / Deny)
               with the id header)
```

## Setup — run all the components

From this directory (`demos/cpex`):

### 1. Bring up the stack + gateway (one command)

`restart.sh` builds the gateway (via `build-gateway.sh`), brings up Keycloak
(with CIBA + the channel SPI), the HR MCP server, the **auth-channel UI**, and
Valkey, then starts the gateway on `:8090`:

```bash
# Point the gateway at a praxis source (see "Configuring the gateway / praxis
# source" in the base README):
PRAXIS_DIR=~/src/praxis ./restart.sh
# ...or PRAXIS_GIT_URL=<url> PRAXIS_GIT_REF=feat/hil_apl ./restart.sh
```

> The gateway needs the `feat/hil_apl` branch (the `policy` filter with the
> HIL/elicitation changes) — point `PRAXIS_DIR` at a local checkout on that
> branch, or set `PRAXIS_GIT_URL`. The script wipes Keycloak/MCP state on each
> run, so it's also how you **reset** the demo (Jane's salary back to the seed
> value).

What comes up:

| Service | URL |
|---|---|
| Praxis-CPEX gateway | `http://localhost:8090/mcp` |
| Keycloak (realm `cpex-demo`) | `http://localhost:8081` |
| HR MCP server | container `:9100` |
| **Approval UI** (Alice's phone) | **`http://localhost:5001`** |
| Valkey (session taint) | `:6379` |

### 2. Pick an LLM for the agent

`chat.py` is litellm-routed and defaults to a local **Ollama** model
(`ollama/qwen3:8b`) — no API key required. Pick another provider with
`--model` (or the `DEMO_MODEL` env var); tool-calling needs a capable model:

```bash
python chat.py --persona bob                                    # ollama (default, no key)
python chat.py --persona bob --model gpt-4o-mini                # OpenAI    (OPENAI_API_KEY)
python chat.py --persona bob --model anthropic/claude-3-7-sonnet-20250219   # Anthropic (ANTHROPIC_API_KEY)
python chat.py --persona bob --model watsonx/meta-llama/llama-3-3-70b-instruct  # IBM watsonx (WATSONX_APIKEY / WATSONX_URL / WATSONX_PROJECT_ID)
```

Set provider credentials via env vars (or `agent/.env`, which is gitignored).

### 3. Run the agent (as Bob)

```bash
cd agent && python chat.py --persona bob
```

Bob is the HR persona whose manager is Alice. Tool-calling reliability scales
with the model — a 70B-class model handles the multi-step flow best.

### 4. Open the approval UI

Put **`http://localhost:5001`** on screen next to the chat — this is Alice's
"phone." It auto-refreshes; pending requests show up with Approve / Deny
buttons.

## Demo script (≈3 min)

> Two panes: the **chat** (Bob talking to the copilot) and the **approval
> UI** (`:5001`, Alice's phone). The UI starts empty.

**1 — Baseline (policy says yes, invisibly).**

```
Bob: look up compensation for EMP-001234
```

The agent returns Jane Smith's record. (Behind the scenes the gateway
checked Bob's role, exchanged his token for a Workday-scoped one, and
audited it — see the base demo.)

**2 — The sensitive ask.**

```
Bob: give Jane (EMP-001234) a $25,000 raise — her Q3 review came in strong
```

The agent calls `adjust_compensation`, the gateway sees it's over the $10k
threshold, and **suspends** it. The agent says something like:

> *That's above the $10K I can approve on your own authority — it needs
> Alice's sign-off. I've sent her the request. Anything else while we wait?*

**On the approval UI**, a request appears: *alice — "Approve-a-compensation-adjustment"*.

**3 — Fill the time (the agent isn't blocked).**

```
Bob: who's in the engineering directory?
Bob: what's a senior salary band look like for EMP-001234?
```

The agent answers normally. The approval is still out; Bob has moved on.

**4 — Alice approves.**

Click **Approve** in the UI (you're Alice). Within a few seconds the chat
prints a toast:

```
🔔 alice approved the pending adjust_compensation request.
```

**5 — The cut-in.** On Bob's next message, the agent folds it in:

```
Bob: thanks — anything else I should know?
Assistant: … By the way, Alice just approved that raise — it's applied.
           Jane's salary is now $150,000.
```

**6 — (Optional) the deny path.** Re-run step 2, then click **Deny** in the
UI. The agent reports that the manager declined and the change was not made.

That's the whole arc: **the agent pauses for a human, lets Bob keep working,
and resurfaces the resolved request on its own** — with the gateway, not the
agent, owning the approval, the binding, and the audit trail.

## Notes & troubleshooting

- **Reset between runs:** re-run `restart.sh` (it wipes volumes), or
  `docker compose down -v && docker compose up -d`. Jane's salary
  accumulates across un-reset runs.
- **Edited the CIBA SPI (or auth-channel / hr-mcp)?** `restart.sh` reuses
  cached container images by default. Re-run it as
  `REBUILD_IMAGES=1 ./restart.sh` to force `docker compose build` first so
  the change is baked in.
- **Approval never lands:** check the UI received the request
  (`http://localhost:5001`), and the channel logs:
  `docker compose logs -f auth-channel`. The gateway log is `./gateway.log`.
- **Token expired during a long pause:** type `relogin` in the chat to mint
  fresh tokens (CIBA requests expire after ~120s by realm policy).
- **Threshold:** adjustments **≤ $10,000 apply immediately** (no approval);
  **> $10,000** require Alice. The approval is bound to the amount
  (`scope: args.amount <= 25000`), so an approval can't be replayed against
  a bigger change.
- **Other personas:** `python chat.py --persona alice` / `--persona eve`
  exercise the base demo's deny / redact scenarios.
