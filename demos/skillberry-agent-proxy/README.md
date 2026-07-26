# Skillberry Agent Proxy — Praxis Agentic Gateway

A fully automated demo of **Praxis** as an agentic gateway for the Skillberry
Agent platform. All services run locally on the host — no Docker required.

## What it shows

| Concern | Demo behavior |
|---------|---------------|
| Client | `emulate_client.py` sends an OpenAI-compatible chat completion |
| Gateway | Praxis on localhost:7000 — skill config injection + LLM routing |
| Worker | FastAPI service (ReAct loop) on localhost:7010 |
| Store | Skill resolution + tool definitions on localhost:8000 |
| LLM | Proxied through Praxis llm-egress (localhost:8081) → LiteLLM |

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
┌───────────────┐        ┌──────────────────────────┐
│     Store     │◂ ─ ─ ─ │    Skillberry Agent      │
│    (:8000)    │         │       (:7010)            │
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
- **Praxis** binary built from source (`cd ~/praxis && cargo build --package praxis-proxy`)
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
5. Create a tmux session (`skillberry-demo`) and start the Worker (port 7010)
6. Start Praxis (port 7000 ingress, port 8081 LLM egress)
7. Run the client emulator and attach to the tmux session

After setup, you're dropped into tmux with 3 windows:
- `0:praxis` — Praxis gateway live output
- `1:worker` — Skillberry Worker live output
- `2:client` — Chat client (re-run anytime)

Use `Ctrl-b n`/`Ctrl-b p` to switch windows, `Ctrl-b d` to detach.

## Stopping and purging

```bash
# Stop all services — kills tmux session + store (preserves cloned repos and venv)
./scripts/stop-demo.sh

# Full cleanup: stop + remove repos, venv, logs
./scripts/purge-demo.sh
```

## Logs

| Service | Where |
|---------|-------|
| Store | `tmp/skillberry-store/service.log` (managed internally) |
| Worker | Live in tmux window `1:worker` |
| Praxis | Live in tmux window `0:praxis` |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SPAPRAXIS_API_KEY` | — | LLM provider API key (required) |
| `SPAPRAXIS_LITELLMPROXY` | — | LiteLLM proxy host:port (required) |
| `SPAPRAXIS_MODEL` | `aws/gpt-oss-120b` | Model name for all LLM calls |
| `SPAPRAXIS_TEMPERATURE` | `0.0` | Temperature for all LLM calls |
| `PRAXIS_BIN` | `~/praxis/target/debug/praxis` | Path to Praxis binary |
| `PRAXIS_ROOT` | `~/praxis` | Praxis source root (for binary lookup) |
| `PYTHON_VERSION` | `python3` | Python interpreter to use |

## Files

| File | Description |
|------|-------------|
| `praxis.yaml.tmpl` | Praxis pipeline template (expanded by envsubst) |
| `skills/praxis-demo-hello-world/` | Demo skill (SKILL.md + 2 Python tools) |
| `scripts/run-demo.sh` | Main entry point — full orchestration |
| `scripts/stop-demo.sh` | Stop all services |
| `scripts/purge-demo.sh` | Stop + remove all generated files |
| `scripts/lib.sh` | Shared utilities (banners, port checks) |
| `scripts/emulate_client.py` | Client that sends a request through the pipeline |
