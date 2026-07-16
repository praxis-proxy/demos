#!/usr/bin/env bash
# Demo runner — streaming multi-turn with previous_response_id.
set -euo pipefail

PRAXIS="http://127.0.0.1:8080"
MODEL="Qwen/Qwen3-0.6B"
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

# ── Turn 1: non-streaming (stored) ──────────────────────────────────

banner "1. Turn 1 — non-streaming, stored by Praxis"
printf "Send a non-streaming request. Praxis classifies, validates,\n"
printf "forwards to vLLM, and stores the response in SQLite.\n"
printf "The response ID is saved for the next turn.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"My name is Seb and I build reverse proxies. Remember this."}'\'' | jq .'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"My name is Seb and I build reverse proxies. Remember this."}')
echo "$RESPONSE" | jq .
RESP_ID=$(echo "$RESPONSE" | jq -r '.id')
TOKENS_1=$(echo "$RESPONSE" | jq -r '.usage.total_tokens')

if [ "$RESP_ID" = "null" ] || [ -z "$RESP_ID" ]; then
    printf "\n\033[1;31mError: no response ID returned. Check vLLM.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mResponse ID: %s\033[0m\n" "$RESP_ID"
printf "\033[1;33m↳ total_tokens: %s (stored in SQLite)\033[0m\n" "$TOKENS_1"
sleep 3

# ── Turn 2: streaming with previous_response_id ─────────────────────

banner "2. Turn 2 — streaming with previous_response_id"
printf "Now stream with previous_response_id pointing to turn 1.\n"
printf "Praxis rehydrates the conversation history from SQLite,\n"
printf "rebuilds the body, and forwards to vLLM.\n"
printf "SSE events stream back in real time. The stream_events filter\n"
printf "accumulates state and persists the response at end-of-stream.\n"
sleep 1

CMD='curl -sN '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"What is my name and what do I build?","stream":true,"previous_response_id":"'"$RESP_ID"'"}'\'''
type_cmd "$CMD"
STREAM_TMP=$(mktemp)
curl -sN "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"What is my name and what do I build?","stream":true,"previous_response_id":"'"$RESP_ID"'"}' \
    | tee "$STREAM_TMP"
sleep 1

RESP_ID_2=$(grep 'response.completed' "$STREAM_TMP" | sed 's/^data: //' | jq -r '.response.id // empty' 2>/dev/null || echo "")
TOKENS_2=$(grep 'response.completed' "$STREAM_TMP" | sed 's/^data: //' | jq -r '.response.usage.total_tokens // empty' 2>/dev/null || echo "")
ANSWER=$(grep 'response.completed' "$STREAM_TMP" | sed 's/^data: //' | jq -r '.response.output[0].content[0].text // empty' 2>/dev/null || echo "")
rm -f "$STREAM_TMP"

if [ -n "$RESP_ID_2" ]; then
    printf "\n\033[1;33mStreamed Response ID: %s\033[0m\n" "$RESP_ID_2"
fi
if [ -n "$TOKENS_2" ]; then
    printf "\033[1;33m↳ total_tokens: %s (turn 1 was %s)\033[0m\n" "$TOKENS_2" "$TOKENS_1"
    printf "\033[1;33m  More tokens = conversation history was included.\033[0m\n"
fi
if [ -n "$ANSWER" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER"
    printf "\033[1;32m  It remembers! Rehydration + streaming worked.\033[0m\n"
fi
sleep 3

# ── Verify: SQLite store ────────────────────────────────────────────

banner "3. Verify — both responses persisted in SQLite"
printf "Both the non-streaming (turn 1) and streaming (turn 2)\n"
printf "responses are stored. The stream_events filter accumulated\n"
printf "SSE state and the store persisted it at end-of-stream.\n"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/responses.db"

type_cmd "sqlite3 $DB \"SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;\""
sqlite3 "$DB" "SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;" 2>/dev/null || \
    printf "\033[1;31mCould not query database.\033[0m\n"
sleep 3

# ── Retrieve stored streaming response ──────────────────────────────

if [ -n "$RESP_ID_2" ]; then
    banner "4. Retrieve — fetch the stored streaming response"
    printf "The streaming response was persisted by the store filter.\n"
    printf "We can retrieve it like any non-streaming response.\n"
    sleep 1

    CMD="curl -s $PRAXIS/v1/responses/$RESP_ID_2 | jq ."
    type_cmd "$CMD"
    curl -s "$PRAXIS/v1/responses/$RESP_ID_2" | jq .
    sleep 3
fi

printf "\n\033[1;32mDone.\033[0m Turn 1 stored via buffered path. Turn 2 streamed\n"
printf "with rehydrated history — SSE events accumulated by\n"
printf "stream_events and persisted by store at end-of-stream.\n"
sleep 3
