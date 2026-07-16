# Recording the assistant demo

`record_chat_demo.py` records the interactive HR assistant (`../chat.py`) as a
demo GIF/MP4. It is the "assistant cut": a real, LLM-driven session in front of
the Praxis-CPEX gateway, captured with asciinema through a two-pane tmux layout.

- **Bottom pane:** `chat.py` talking to the gateway.
- **Top pane:** the exact `cpex.yaml` policy that governs each step, spotlighted
  just before the agent acts on it, plus the manager's out-of-band approval
  during the human-in-the-loop beat.

The flow exercises the headline features in one continuous session: allow with
RFC 8693 delegation, session taint blocking exfiltration, APL deny, Cedar
allow/deny, on-the-wire SSN redaction, and the CIBA manager-approval flow.

## Prerequisites

1. **The full stack up.** From `demos/cpex`, run `./restart.sh` with the
   `feat/hil_apl` gateway (see the [demo README](../../README.md)). If `hr-mcp`
   was built before `adjust_compensation` existed, rebuild it once:
   `docker compose build hr-mcp && docker compose up -d hr-mcp`. The preflight
   check flags this.
2. **A capable model.** The recording drives real tool calls, so set `DEMO_MODEL`
   to a model that tool-calls reliably (70B-class, `gpt-4o`, or a Claude model)
   and export its provider credentials. The local `ollama` default drops tool
   calls mid-flow and will produce a broken recording.
3. **Tools on PATH:** `tmux` and `asciinema` to record, `agg` and `ffmpeg` to
   convert to GIF/MP4.

## Usage

```bash
cd demos/cpex/agent

python demo/record_chat_demo.py --check          # preflight only, no recording

DEMO_MODEL=watsonx/meta-llama/llama-3-3-70b-instruct \
    python demo/record_chat_demo.py --record     # record -> chat-demo.{cast,gif,mp4}

python demo/record_chat_demo.py --gif-only        # re-convert an existing cast
python demo/record_chat_demo.py --verify          # check the demo markers landed
python demo/record_chat_demo.py --no-cleanup      # keep the tmux session to debug
```

Artifacts (`chat-demo.cast`, `.gif`, `.mp4`) are written here and gitignored.

## How it drives the session

The harness sends prompts to the chat pane with `tmux send-keys` and waits for
the agent to return to its input prompt before moving on (it does not rely on
output stability, since the LLM can think silently for several seconds). For the
human-in-the-loop beat it waits for the gateway's `-32120` "pending", approves
out-of-band by calling the auth-channel `/pending` + `/approve` endpoints (shown
in the top pane), then waits for `chat.py`'s background poller to surface the
approval so the agent resumes on its own, and confirms to apply.

`test_chat_demo.py` holds free ($0.00) tests that guard the act list against
drift and check that every policy spotlight renders. A `DEMO_ENABLE_LIVE=1`
test runs the preflight against a running stack.
