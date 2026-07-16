#!/usr/bin/env bash
# Record the multi-turn demo with asciinema inside a tmux session.
#
# Layout:
#   ┌─────────────────────┬────────────────────┐
#   │  vLLM logs          │  Praxis logs       │
#   ├─────────────────────┴────────────────────┤
#   │  curl commands (demo runner)             │
#   └──────────────────────────────────────────┘
#
# Prerequisites:
#   - vLLM running: podman run --name vllm ...
#   - praxis on $PATH (or set PRAXIS_BIN)
#
# Usage:
#   ./record.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAST_FILE="$SCRIPT_DIR/demo.cast"
SESSION="praxis-multi-turn-demo"
PRAXIS_BIN="${PRAXIS_BIN:-$(command -v praxis 2>/dev/null || echo "")}"
CONFIG="$SCRIPT_DIR/multi-turn.yaml"

if [ -z "$PRAXIS_BIN" ] || [ ! -f "$PRAXIS_BIN" ]; then
    echo "error: praxis not found. Either:"
    echo "  - add it to PATH"
    echo "  - set PRAXIS_BIN=/path/to/praxis"
    exit 1
fi

# Kill any leftover session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Kill any praxis already on :8080
lsof -ti :8080 | xargs kill 2>/dev/null || true
sleep 0.5

# Clean up any leftover SQLite DB from previous runs
rm -f "$SCRIPT_DIR/responses.db"*

# Top-left: vLLM logs
tmux new-session -d -s "$SESSION" -x 120 -y 40 \
    "printf '\033[1;35m── vLLM Logs ──\033[0m\n'; \
     podman logs -f vllm 2>&1 | grep --line-buffered -vE '^$'"

# Top-right: Praxis logs
tmux split-window -h -t "$SESSION" \
    "printf '\033[1;33m── Praxis Logs ──\033[0m\n'; \
     cd $SCRIPT_DIR && \
     RUST_LOG=praxis_filter=debug $PRAXIS_BIN -c $CONFIG 2>&1 \
     | grep --line-buffered -E 'classified|mode|stateless|stateful|rehydrat|responses_proxy|rebuild|store|persist|route matched|upstream selected|listening|ready'"

sleep 1

# Bottom: curl demo (spans full width)
tmux split-window -v -t "$SESSION" -p 55 \
    "$SCRIPT_DIR/run-demo.sh; tmux wait-for -S demo-done"

# Select the bottom pane so it's focused during recording
tmux select-pane -t "$SESSION":0.2

# Record the full tmux session
asciinema rec \
    --overwrite \
    --title "Praxis — OpenAI Responses API Multi-Turn (Non-Streaming)" \
    --idle-time-limit 3 \
    --command "tmux attach -t $SESSION" \
    "$CAST_FILE"

# Cleanup
tmux kill-session -t "$SESSION" 2>/dev/null || true
lsof -ti :8080 | xargs kill 2>/dev/null || true

printf "\nRecording saved to %s\n" "$CAST_FILE"
