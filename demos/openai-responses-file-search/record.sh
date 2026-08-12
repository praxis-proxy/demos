#!/usr/bin/env bash
# Record the file search demo with asciinema inside a tmux session.
#
# Layout:
#   ┌─────────────────────┬────────────────────┐
#   │  OGX                │  vLLM logs         │
#   ├─────────────────────┴────────────────────┤
#   │  Praxis logs                             │
#   ├──────────────────────────────────────────┤
#   │  curl commands (demo runner)             │
#   └──────────────────────────────────────────┘
#
# Prerequisites:
#   - vLLM running: podman run --name vllm ...
#   - OGX running: cd /path/to/ogx && uv run ogx run starter --insecure
#   - praxis-ai on $PATH (or set PRAXIS_BIN)
#
# Usage:
#   ./record.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAST_FILE="$SCRIPT_DIR/demo.cast"
SESSION="praxis-file-search-demo"
PRAXIS_BIN="${PRAXIS_BIN:-$(command -v praxis-ai 2>/dev/null || echo "")}"
CONFIG="$SCRIPT_DIR/file-search.yaml"

# Resolve to absolute path (relative paths break after cd)
if [ -n "$PRAXIS_BIN" ] && [ -f "$PRAXIS_BIN" ]; then
    PRAXIS_BIN="$(cd "$(dirname "$PRAXIS_BIN")" && pwd)/$(basename "$PRAXIS_BIN")"
else
    echo "error: praxis-ai not found. Either:"
    echo "  - add it to PATH"
    echo "  - set PRAXIS_BIN=/path/to/praxis-ai"
    exit 1
fi

# Kill any leftover session
tmux kill-session -t "$SESSION" &>/dev/null || true

# Kill any praxis already on :8080
lsof -ti :8080 | xargs kill &>/dev/null || true
sleep 0.5

# ── Build the 4-pane layout ──────────────────────────────────────────
#
# Build top-down with stable pane targeting:
#   1. new-session → pane 0 (OGX, top-left)
#   2. split 0 vertically → 0=OGX top, 1=Praxis bottom-half
#   3. split 1 vertically → 1=Praxis middle, 2=curl bottom
#   4. split 0 horizontally → 0=OGX left, 3=vLLM right
#
# Each pane ends with `read` so it stays open even if the
# command exits early (prevents pane index shifts).

# Pane 0: OGX (top-left)
tmux new-session -d -s "$SESSION" -x 200 -y 50 \
    "printf '\033[1;34m── OGX ──\033[0m\n'; \
     cd /Users/leseb/Documents/AI/ogx && uv run ogx run starter --insecure 2>&1; \
     echo 'OGX exited'; read"

# Wait for OGX to be ready (it's starting in pane 0)
printf "Waiting for OGX on :8321..."
for i in $(seq 1 60); do
    if curl -s -o /dev/null http://127.0.0.1:8321/v1/files 2>/dev/null; then
        printf " ready.\n"
        break
    fi
    printf "."
    sleep 1
done

# Pane 1: Praxis (middle row, full width)
tmux split-window -v -t "${SESSION}:0.0" -p 70 \
    "printf '\033[1;33m── Praxis Logs ──\033[0m\n'; \
     cd $SCRIPT_DIR && \
     RUST_LOG=praxis_filter=debug $PRAXIS_BIN -c $CONFIG 2>&1 \
     | grep --line-buffered -E 'classified|file_search|vector_store|callout|search|iteration|transition|pending|tool_parse|function_call|fan.out|route matched|upstream selected|listening|ready|error|ERROR|panic|WARN|warn|unknown|invalid|failed'; \
     echo 'Praxis exited'; read"

# Pane 2: curl demo (bottom row, full width)
tmux split-window -v -t "${SESSION}:0.1" -p 50 \
    "$SCRIPT_DIR/run-demo.sh; tmux wait-for -S demo-done"

# Pane 3: vLLM logs (top-right, split from OGX)
tmux split-window -h -t "${SESSION}:0.0" -p 50 \
    "printf '\033[1;35m── vLLM Logs ──\033[0m\n'; \
     podman logs -f vllm 2>&1 | grep --line-buffered -vE '^\$'; \
     echo 'vLLM logs ended — is the container running?'; read"

# Focus the curl pane
tmux select-pane -t "${SESSION}:0.2"

sleep 2

# Record the full tmux session
asciinema rec \
    --overwrite \
    --title "Praxis — File Search via Vector Store Callout" \
    --idle-time-limit 3 \
    --command "tmux attach -t $SESSION" \
    "$CAST_FILE"

# Cleanup
tmux kill-session -t "$SESSION" &>/dev/null || true
lsof -ti :8080 | xargs kill &>/dev/null || true

printf "\nRecording saved to %s\n" "$CAST_FILE"
