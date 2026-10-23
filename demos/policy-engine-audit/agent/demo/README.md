# Recording the live demo

`record_chat_demo.py` records the live chat demo (`../chat.py`, the four beats
in [CHAT.md](../CHAT.md)) as an asciinema cast, plus a GIF and an MP4. It is
adapted from the policy-engine demo's recorder in praxis-proxy/demos. A real,
LLM-driven session runs in front of the Praxis gateway inside a three-pane
tmux layout, captured headlessly:

- **Top left, POLICY:** the `config/policy.yaml` rule that governs the next
  step, spotlighted just before the agent acts on it; at the close, how the
  receipt is produced.
- **Top right, RECORDS:** the gateway's OCSF records as they land, one line per
  ruling, in the shape `tools/watch-records.sh` prints (denies in red).
- **Bottom:** `chat.py` talking to the gateway. After the last beat it quits
  and the same pane ships the chat's records to the ARE ledger and verifies
  the receipt for the refused email.

`--layout side` is the arrangement used when presenting live: `chat.py` down
the right half, the policy pane above the records pane on the left. A deny's
reason moves to its own line there so the records pane never wraps.

## Prerequisites

1. **The stack up.** From the demo directory run `./run-demo.sh` once. It
   leaves the gateway (:8090), Keycloak (:8081, `cpex-demo` realm), the HR MCP
   server (:9100), Valkey and the ARE ledger (:18080, :19292) running and
   `out/gateway.stderr` in place.
2. **A capable model.** Set `DEMO_MODEL` to a model that tool-calls reliably
   (`gpt-4o`, a Claude model, or a 70B-class model) and export its provider
   key. The local `ollama` default drops tool calls mid-flow and produces a
   broken recording.
3. **The chat venv active**, with `requirements.txt` and the ledger adapter's
   requirements (`.ledger/adapters/cpex/requirements.txt`) installed, so the
   close can reach the ledger. `run-demo.sh` fetches `.ledger/` on first run.
4. **Tools on PATH:** `tmux` and `asciinema` to record, `agg` and `ffmpeg` to
   convert. On macOS: `brew install tmux asciinema agg ffmpeg`.

## Usage

Run from the `agent` directory:

```bash
python demo/record_chat_demo.py --check        # preflight only, no recording

DEMO_MODEL=gpt-4o python demo/record_chat_demo.py --record   # -> chat-demo.{cast,gif,mp4}
DEMO_MODEL=gpt-4o python demo/record_chat_demo.py --record --layout side

python demo/record_chat_demo.py --gif-only     # re-convert an existing cast
python demo/record_chat_demo.py --verify       # check the demo markers landed
python demo/record_chat_demo.py --no-cleanup   # keep the tmux session to debug
```

The artifacts (`chat-demo.cast`, `.gif`, `.mp4`) are written here and
gitignored. To publish, `asciinema upload demo/chat-demo.cast` and put the
link in the README's "Watch it run" section.

## Driving it yourself

`../../tools/record-live.sh` records the same two-pane layout while you type
the beats: the records pane on the left, `chat.py` on the right, captured with
asciinema until you detach from tmux (`Ctrl-b`, then `d`). It writes
`chat-live.cast` here.

## How it drives the session

The harness types each prompt into the chat pane with `tmux send-keys` and
waits for the agent to return to its input prompt before moving on (it does not
rely on output stability, since the model can think silently for several
seconds). It records how many records exist when it starts, so the close ships
only the records this chat produced. `--verify` checks that the banner, a
`Blocked` record, the `session_tainted_secret` refusal, `[REDACTED]` and a valid
ledger receipt all made it into the cast.
