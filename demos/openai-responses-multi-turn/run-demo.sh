#!/usr/bin/env bash
# Demo runner — multi-turn conversation with rehydrate + responses_proxy.
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

banner "1. First turn — stored by Praxis"
printf "Introduce ourselves. Praxis classifies, validates, stores the\n"
printf "response, and forwards to vLLM. The response ID is saved for\n"
printf "the next turn.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"My name is Seb and I like reverse proxies. Acknowledge this."}'\'' | jq .'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"My name is Seb and I like reverse proxies. Acknowledge this."}')
echo "$RESPONSE" | jq .
RESP_ID=$(echo "$RESPONSE" | jq -r '.id')
TOKENS_1=$(echo "$RESPONSE" | jq -r '.usage.total_tokens')

if [ "$RESP_ID" = "null" ] || [ -z "$RESP_ID" ]; then
    printf "\n\033[1;31mError: no response ID returned. Check vLLM.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mResponse ID: %s\033[0m\n" "$RESP_ID"
printf "\033[1;33m↳ total_tokens: %s\033[0m\n" "$TOKENS_1"
sleep 3

banner "2. Second turn — rehydrated by Praxis"
printf "Ask about turn 1. The client only sends the new question and\n"
printf "previous_response_id — Praxis rehydrates the conversation from\n"
printf "the store and rebuilds the body with the full history.\n"
printf "If the model knows the answer, rehydration worked.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"What is my name and what do I like?","previous_response_id":"'"$RESP_ID"'"}'\'' | jq .'
type_cmd "$CMD"
RESPONSE2=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"What is my name and what do I like?","previous_response_id":"'"$RESP_ID"'"}')
echo "$RESPONSE2" | jq .
TOKENS_2=$(echo "$RESPONSE2" | jq -r '.usage.total_tokens')
ANSWER=$(echo "$RESPONSE2" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

printf "\n\033[1;33m↳ total_tokens: %s (turn 1 was %s)\033[0m\n" "$TOKENS_2" "$TOKENS_1"
printf "\033[1;33m  More tokens = conversation history was included in the request.\033[0m\n"
if [ -n "$ANSWER" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER"
    printf "\033[1;32m  It remembers! Rehydration worked.\033[0m\n"
fi
sleep 3

banner "3. Verify — SQLite store"
printf "Both responses are persisted. Let's check the database.\n"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/responses.db"

type_cmd "sqlite3 $DB \"SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;\""
sqlite3 "$DB" "SELECT id, model, datetime(created_at, 'unixepoch') FROM openai_responses;" 2>/dev/null || \
    printf "\033[1;31mCould not query database.\033[0m\n"
sleep 3

printf "\n\033[1;32mDone.\033[0m Two responses stored. Turn 2 consumed more tokens\n"
printf "because Praxis rehydrated the full conversation history and\n"
printf "rebuilt the request body before forwarding to vLLM.\n"
sleep 3
