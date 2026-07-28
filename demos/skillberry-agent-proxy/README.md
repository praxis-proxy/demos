# Skillberry Agent Proxy — Praxis Agentic Gateway

A fully automated demo of **Praxis** as an agentic gateway for the Skillberry
Agent platform, based on [skillberry-agent-praxis-poc](https://github.com/skillberry-ai/skillberry-agent-praxis-poc).

## What it shows

| Step | What happens |
|------|--------------|
| 1 | Client sends an OpenAI-compatible chat completion to Praxis (:7000) |
| 2 | Praxis injects skill config and forwards to Worker (:7010) |
| 3 | Worker resolves the skill from the Store (:8000), runs a ReAct agent loop |
| 4 | Worker's LLM calls go through Praxis egress (:8081), which injects credentials and routes to LiteLLM |
| 5 | Final response flows back through the pipeline to the client |

### Key behaviors

- **Credential isolation** — the client never sends a real API key; Praxis injects it on the egress path.
- **Model policy** — Praxis overrides the client's model/temperature with its own configured values.

## Architecture

```text
                             ┌─────────────────────┐
     ┌─────────┐             │       Praxis        │
     │  User   │────────────▸│  ┌───────────────┐  │
     └─────────┘             │  │   Ingress     │  │
                             │  │   (:7000)     │  │
                             │  └───────┬───────┘  │
                             │          │          │
                             └──────────┼──────────┘
                                        │
                                        v
┌───────────────┐         ┌─────────────────────────┐
│     Store     │◂ ─ ─ ─  │    Skillberry Agent     │
│    (:8000)    │         │       (:7010)           │
│  ┌─────────┐  │         │  ┌──────────────────┐   │
│  │  tools  │  │         │  │  Business Logic  │   │
│  │  skills │  │         │  │  (ReAct loop)    │   │
│  └─────────┘  │         │  └────────┬─────────┘   │
└───────────────┘         └───────────┼─────────────┘
                                      │
                             ┌────────┼──────────┐
                             │        v          │
                             │  ┌───────────────┐│
                             │  │   Egress      ││
                             │  │   (:8081)     ││
                             │  └───────┬───────┘│
                             │       Praxis      │
                             └──────────┼────────┘
                                        │
                                        v
                             ┌───────────────────┐
                             │       LLM         │
                             │  (LiteLLM Proxy)  │
                             └───────────────────┘
```

## Prerequisites

- **Platform:** Linux or macOS
- **Python 3.11+**
- **tmux**
- **Praxis** built from source (`cargo build -p praxis-proxy --release`)
- **curl**, **jq**, **envsubst** (`brew install gettext` on macOS), **git**

## Quick start

```bash
cd demos/skillberry-agent-proxy

# Set required environment variables
export SPAPRAXIS_API_KEY="<your-llm-provider-key>"
export SPAPRAXIS_LITELLMPROXY="<your-litellm-proxy-host:port>"

# Run the full demo
./scripts/run-demo.sh
```

The script will:
1. Check prerequisites and port availability
2. Clone and install store + worker into a local `.venv`
3. Start the Skillberry Store (port 8000)
4. Import the demo skill
5. Create a tmux session
6. Start Praxis (port 7000 ingress, port 8081 LLM egress)
7. Start the Worker (port 7010)
8. Query and display the imported skill (tools + snippets) from the Store API
9. Run the client emulator in the foreground, then attach to the tmux session

After setup, you're dropped into tmux with 3 windows:
- `0:praxis` — Praxis gateway live output
- `1:worker` — Skillberry Worker live output
- `2:client` — Chat client (re-run anytime for subsequent requests)

Use `Ctrl-b n`/`Ctrl-b p` to switch windows, `Ctrl-b d` to detach, `Ctrl-b [` to enter scroll mode (navigate with arrow keys or PgUp/PgDn, `q` to exit).

```bash
# Stop all services (preserves cloned repos and venv)
./scripts/stop-demo.sh

# Full cleanup: stop + remove repos, venv, logs
./scripts/purge-demo.sh
```

## What to look for

### Praxis logs (tmux window `0:praxis`)

- `filter=access_log` lines showing requests flowing through ingress and egress

### Worker logs (tmux window `1:worker`)

- `Resolved skill UUID:` — confirms the store resolved the skill
- `MCP tools retrieved:` — shows tool count loaded from the skill
- `execute_agentic_graph started/ended` — brackets the ReAct loop

### Client logs (tmux window `2:client`)

- `Listing available tools` — shows the available tools per client (prompt) request

### Store log

- Located at `/tmp/skillberry-store.log`

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SPAPRAXIS_API_KEY` | — | LLM provider API key (required) |
| `SPAPRAXIS_LITELLMPROXY` | — | LiteLLM proxy host:port (required) |
| `SPAPRAXIS_MODEL` | `aws/gpt-oss-120b` | Model name for all LLM calls |
| `SPAPRAXIS_TEMPERATURE` | `0.0` | Temperature for all LLM calls |
| `PRAXIS_BIN` | `~/praxis/target/debug/praxis` | Path to Praxis binary |
| `PRAXIS_ROOT` | `~/praxis` | Praxis source root (for binary lookup) |

## Files

| Path | Description |
|------|-------------|
| `praxis.yaml.tmpl` | Praxis pipeline template (expanded by envsubst) |
| `skills/praxis-demo-hello-world/` | Demo skill (SKILL.md + 2 Python tools) |
| `scripts/run-demo.sh` | Main entry point — 9-step walkthrough orchestration |
| `scripts/stop-demo.sh` | Stop all services |
| `scripts/purge-demo.sh` | Stop + remove all generated files |
| `scripts/lib.sh` | Shared utilities (banners, port checks, health waits) |
| `scripts/emulate_client.py` | Client that sends a chat completion through the pipeline |
| `.gitignore` | Ignores generated dirs: `tmp/`, `artifacts/`, `.venv/` |
