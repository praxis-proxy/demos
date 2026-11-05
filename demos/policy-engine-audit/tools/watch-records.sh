#!/bin/bash
# Follow the gateway's OCSF records as they land, one line per ruling, in the
# same shape the scenarios print. Run it in a second pane next to chat.py so
# the audience sees each verdict become a signed record the moment it happens.
#
#   tools/watch-records.sh          # summary lines (seq, tool, phase, verdict)
#   tools/watch-records.sh --raw    # the full OCSF JSON, one record per line
set -euo pipefail
source "$(dirname "$0")/../scenarios/_lib.sh"

[ -f "$GATEWAY_STDERR" ] || fail "no records yet at $GATEWAY_STDERR; start the gateway first (tools/gateway.sh start)"

echo -e "${DIM}following $GATEWAY_STDERR (Ctrl-C to stop)${RESET}"
if [ "${1:-}" = "--raw" ]; then
    tail -n 0 -F "$GATEWAY_STDERR" | grep --line-buffered '^{' | jq --unbuffered -c .
else
    tail -n 0 -F "$GATEWAY_STDERR" | grep --line-buffered '^{' | summarize
fi
