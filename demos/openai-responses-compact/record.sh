#!/usr/bin/env bash
# Record the compaction demo with asciinema inside a tmux session.
#
# Layout:
#   ┌──────────────────────────────────────┐
#   │  Praxis logs (filtered)              │
#   ├──────────────────────────────────────┤
#   │  curl commands (demo runner)         │
#   └──────────────────────────────────────┘
#
# Prerequisites:
#   - Ollama running on :11434 with the model pulled:
#       ollama serve &            # if not already running
#       ollama pull llama3.2:1b   # or set MODEL=<name>
#   - praxis-ai on $PATH (or set PRAXIS_BIN)
#   - asciinema and tmux installed
#
# Usage:
#   ./record.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CAST_FILE="$SCRIPT_DIR/demo.cast"
SESSION="praxis-compact-demo"
PRAXIS_BIN="${PRAXIS_BIN:-$(command -v praxis-ai 2>/dev/null || echo "")}"
CONFIG="$SCRIPT_DIR/compact.yaml"

# Resolve to absolute path (relative paths break after cd)
if [ -n "$PRAXIS_BIN" ] && [ -f "$PRAXIS_BIN" ]; then
    PRAXIS_BIN="$(cd "$(dirname "$PRAXIS_BIN")" && pwd)/$(basename "$PRAXIS_BIN")"
else
    echo "error: praxis-ai not found. Either:"
    echo "  - add it to PATH"
    echo "  - set PRAXIS_BIN=/path/to/praxis-ai"
    exit 1
fi

# Sanity-check the backend is reachable before recording
if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "error: Ollama not reachable on :11434. Start it with 'ollama serve'"
    echo "       and 'ollama pull ${MODEL:-llama3.2:1b}'."
    exit 1
fi

# Kill any leftover session
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Kill any praxis already on :8080
lsof -ti :8080 | xargs kill 2>/dev/null || true
sleep 0.5

# Clean up any leftover SQLite DB from previous runs
rm -f "$SCRIPT_DIR/responses.db"*

# Top: Praxis logs (filtered to the compaction story).
#
# Scope RUST_LOG to the compact/rehydrate targets only. Enabling debug for
# the whole praxis_filter crate floods the pane with build-time lines like
# "build_branch: filter added to pipeline"; scoping avoids that at the
# source. The grep keeps the story beats and the sed strips the wide
# `http_request{...}:filter{...}:` span prefix so each line stays readable.
COMPACT_LOG="praxis_ai_apis::openai::responses::compact=debug"
REHYDRATE_LOG="praxis_ai_apis::openai::responses::rehydrate=debug"
tmux new-session -d -s "$SESSION" -x 120 -y 40 \
    "printf '\033[1;33m── Praxis Logs ──\033[0m\n'; \
     cd $SCRIPT_DIR && \
     RUST_LOG=info,$COMPACT_LOG,$REHYDRATE_LOG $PRAXIS_BIN -c $CONFIG 2>&1 \
     | grep --line-buffered -E 'listener registered|state populated|token count|threshold|compacting|skipping|summar' \
     | sed -u -E 's/\{[^}]*\}//g'"

sleep 1

# Bottom: curl demo. When it finishes, kill the session so the tmux
# attach (and therefore asciinema rec) exits and the cast ends cleanly —
# otherwise the top pane streams Praxis logs forever.
tmux split-window -v -t "$SESSION" -p 60 \
    "MODEL=${MODEL:-llama3.2:1b} $SCRIPT_DIR/run-demo.sh; sleep 2; tmux kill-session -t $SESSION"

# Select the bottom pane so it's focused during recording
tmux select-pane -t "$SESSION":0.1

# Record the full tmux session
asciinema rec \
    --overwrite \
    --title "Praxis — OpenAI Responses API History Compaction" \
    --idle-time-limit 3 \
    --command "tmux attach -t $SESSION" \
    "$CAST_FILE"

# Cleanup
tmux kill-session -t "$SESSION" 2>/dev/null || true
lsof -ti :8080 | xargs kill 2>/dev/null || true

printf "\nRecording saved to %s\n" "$CAST_FILE"
