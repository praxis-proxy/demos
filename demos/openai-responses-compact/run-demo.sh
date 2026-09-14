#!/usr/bin/env bash
# Demo runner — OpenAI Responses API history compaction.
#
# Turn 1 is stored. Turn 2 rehydrates the stored history and, once it
# crosses compact_threshold, summarizes the prior turns via an inference
# callout before forwarding. Finally, the explicit /v1/responses/compact
# endpoint returns a response.compaction object directly.
#
# Requires an OpenAI-compatible backend on :11434 (Ollama).
set -euo pipefail

PRAXIS="http://127.0.0.1:8080"
MODEL="${MODEL:-llama3.2:1b}"
TYPE_DELAY=0.04

type_cmd() {
    local cmd="$1"
    printf "\n"
    printf '\033[1;32m$ \033[0m'
    for (( i=0; i<${#cmd}; i++ )); do
        printf '%s' "${cmd:$i:1}"
        sleep "$TYPE_DELAY"
    done
    printf "\n"
    sleep 0.3
}

banner() {
    printf "\n\033[1;36m## %s\033[0m\n" "$1"
    sleep 1.5
}

sleep 2

# ── Step 1: Store a detailed first turn ─────────────────────────────

banner "1. First turn — stored by Praxis"
printf "Ask for a long, detailed answer so the stored history is large.\n"
printf "Praxis classifies, validates, forwards to the backend, and stores\n"
printf "the response in SQLite. We capture the response ID for turn 2.\n"
sleep 1

PROMPT1='Explain TCP vs UDP in extensive detail: handshakes, reliability, ordering, flow control, congestion control, head-of-line blocking, and typical use cases. Write at least 600 words.'
CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"'"$PROMPT1"'"}'\'' | jq "{id, status, tokens: .usage.total_tokens}"'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"'"$PROMPT1"'"}')
echo "$RESPONSE" | jq '{id, status, tokens: .usage.total_tokens}'
RESP_ID=$(echo "$RESPONSE" | jq -r '.id')

if [ "$RESP_ID" = "null" ] || [ -z "$RESP_ID" ]; then
    printf "\n\033[1;31mError: no response ID returned.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mResponse ID: %s\033[0m\n" "$RESP_ID"
sleep 3

# ── Step 2: Reactive compaction on the follow-up ────────────────────

banner "2. Follow-up — history over threshold triggers compaction"
printf "The client sends ONLY previous_response_id plus a compaction\n"
printf "block (compact_threshold=1000). Praxis rehydrates the stored\n"
printf "history; because it exceeds the threshold, the compact filter\n"
printf "summarizes the prior turns via an inference callout, then forwards\n"
printf "only the summary + the current question.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Now compare both with QUIC.","previous_response_id":"'"$RESP_ID"'","context_management":[{"type":"compaction","compact_threshold":1000}],"store":false}'\'' | jq "{id, status, output: (.output[0].content[0].text[0:300] + \" …\")}"'
type_cmd "$CMD"
# Truncate the model answer for a legible cast; the full text is real.
curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"Now compare both with QUIC.","previous_response_id":"'"$RESP_ID"'","context_management":[{"type":"compaction","compact_threshold":1000}],"store":false}' \
    | jq '{id, status, output: (.output[0].content[0].text[0:300] + " …")}'
sleep 3

printf "\n\033[1;33m↳ Watch the Praxis log pane: rehydrated history exceeded the\n"
printf "  threshold, so the prior turns were summarized before forwarding.\033[0m\n"
sleep 3

# ── Step 3: Explicit compaction endpoint ────────────────────────────

banner "3. Explicit compaction — POST /v1/responses/compact"
printf "Ask Praxis to compact the stored history on demand. It returns a\n"
printf "response.compaction object with the summary output and usage —\n"
printf "no turn is forwarded to inference.\n"
sleep 1

# The summary rides in output[].encrypted_content (base64) per the
# OpenAI compaction contract; @base64d decodes it, truncated for the cast.
CMD='curl -s '"$PRAXIS"'/v1/responses/compact -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","previous_response_id":"'"$RESP_ID"'"}'\'' | jq "{object, type: .output[0].type, summary: ((.output[0].encrypted_content | @base64d)[0:300] + \" …\"), usage}"'
type_cmd "$CMD"
curl -s "$PRAXIS"/v1/responses/compact \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","previous_response_id":"'"$RESP_ID"'"}' \
    | jq '{object, type: .output[0].type, summary: ((.output[0].encrypted_content | @base64d)[0:300] + " …"), usage}'
sleep 3

printf "\n\033[1;32mDone.\033[0m History compaction — a large stored conversation\n"
printf "collapsed into a short summary, both reactively on a follow-up and\n"
printf "explicitly via /v1/responses/compact, keeping the forwarded context\n"
printf "under the token threshold.\n"
sleep 3
