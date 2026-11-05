#!/bin/bash
# Record a hand-driven run of the chat demo as an asciinema cast.
#
# Opens one tmux window laid out like the live presentation, the records
# pane on the left (the recorder's folded watcher) and chat.py on the right, then records it with
# asciinema while YOU type the beats (agent/CHAT.md). Detach from tmux
# (Ctrl-b, then d) to stop the recording.
#
#   tools/record-live.sh                 # writes agent/demo/chat-live.cast
#   tools/record-live.sh path/to/x.cast  # somewhere else
#
# Needs: tmux and asciinema on PATH, the stack up (./run-demo.sh), the chat
# venv active, DEMO_MODEL and its provider key exported. The agent/demo
# recorder (record_chat_demo.py) is the unattended version of this.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CAST="${1:-$DEMO_DIR/agent/demo/chat-live.cast}"
SESSION="praxis-audit-live"
COLS=160; ROWS=48; CHAT_COLS=88

for tool in tmux asciinema; do
    command -v "$tool" >/dev/null || { echo "  ✗ $tool not on PATH (brew install $tool)"; exit 1; }
done
[ -f "$DEMO_DIR/out/gateway.stderr" ] || { echo "  ✗ no out/gateway.stderr; run ./run-demo.sh first"; exit 1; }
PY="$(command -v python)"
"$PY" -c "import litellm, rich, httpx" 2>/dev/null ||
    { echo "  ✗ python ($PY) lacks the chat deps; activate the chat venv first"; exit 1; }

# tmux shrinks the window to this terminal when it attaches, so the cast is
# only the 160x48 layout if the terminal is at least that big. Ask the tty
# itself: macOS tput answers 80x24 inside a command substitution because its
# stdout is a pipe, whatever the window size.
size="$(stty size </dev/tty 2>/dev/null || echo "0 0")"
lines="${size%% *}"; cols="${size##* }"
if [ "$cols" -lt "$COLS" ] || [ "$lines" -lt "$ROWS" ]; then
    echo "  ✗ this terminal is ${cols}x${lines}; the layout needs ${COLS}x${ROWS}. Make the window bigger (full screen) and rerun."
    exit 1
fi

tmux kill-session -t "$SESSION" 2>/dev/null || true
tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" -c "$DEMO_DIR"
tmux set-option -t "$SESSION" status off   # keep the status bar out of the cast
# A wheel scroll over the records pane would put it in copy mode (the pane
# shows "[0/0]" top right) and freeze its output for the rest of the take.
tmux set-option -t "$SESSION" mouse off
# tmux scrolls a side-by-side pane with DECSLRM left-right margins when the
# terminal advertises them (Ghostty does). The asciinema web player does not
# implement DECSLRM, so each chat-pane scroll would drag the records pane off
# screen in the browser. Drop the margin capabilities and tmux redraws instead.
tmux set-option -s terminal-overrides ',*:Enmg@:Clmg@:Cmg@:Dsmg@'
tmux split-window -h -t "$SESSION" -l "$CHAT_COLS" -c "$DEMO_DIR/agent"
left="$(tmux list-panes -t "$SESSION" -F '#{pane_left} #{pane_id}' | sort -n | head -1 | cut -d' ' -f2)"
right="$(tmux list-panes -t "$SESSION" -F '#{pane_left} #{pane_id}' | sort -n | tail -1 | cut -d' ' -f2)"

# Set both panes up BEFORE recording, so the venv path and the launch lines
# never appear in the cast: the recording opens on the watcher and the chat
# banner. The pane shells are fresh login shells, hence the PATH export.
venv_bin="$(dirname "$PY")"
tmux send-keys -t "$left"  "export PATH=\"$venv_bin:\$PATH\"; PS1=''; stty -echo; clear; python agent/demo/record_chat_demo.py records --width 70" Enter
tmux send-keys -t "$right" "export PATH=\"$venv_bin:\$PATH\"; PS1='$ '; clear; python chat.py --persona bob" Enter
printf '  waiting for chat.py'
for _ in $(seq 1 60); do
    tmux capture-pane -t "$right" -p | grep -q 'Praxis Policy Engine HR Demo' && break
    printf '.'; sleep 1
done
echo
tmux capture-pane -t "$right" -p | grep -q 'Praxis Policy Engine HR Demo' ||
    { echo "  ✗ chat.py did not start; the pane shows:"; tmux capture-pane -t "$right" -p | grep -v '^\s*$'; tmux kill-session -t "$SESSION"; exit 1; }
# Drop the setup lines from both panes' scrollback so a resize cannot bring
# them back into view during the recording.
tmux clear-history -t "$left"; tmux clear-history -t "$right"

cat <<MSG

  Recording to $CAST
  You are driving: type the beats in the RIGHT pane (agent/CHAT.md).
  When done, type quit in the chat, then press Ctrl-b and d to stop.

MSG
asciinema rec "$CAST" --overwrite --window-size "${COLS}x${ROWS}" --idle-time-limit 5 \
    --command "tmux attach -t $SESSION"
tmux kill-session -t "$SESSION" 2>/dev/null || true
echo
echo "  ✓ $CAST"
echo "    play it:    asciinema play \"$CAST\""
echo "    publish it: asciinema upload \"$CAST\""
