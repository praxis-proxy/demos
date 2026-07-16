#!/usr/bin/env bash
# Demo runner — conversation-based multi-turn with rehydrate + append-back.
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

# ── Step 1: Create a conversation ────────────────────────────────────

banner "1. Create a conversation"
printf "Create a conversation with metadata. This is a lightweight\n"
printf "container — no items yet, just an ID we can reference.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/conversations -H "Content-Type: application/json" -d '\''{"metadata":{"project":"demo","topic":"reverse proxies"}}'\'' | jq .'
type_cmd "$CMD"
CONV_RESPONSE=$(curl -s "$PRAXIS"/v1/conversations \
    -H "Content-Type: application/json" \
    -d '{"metadata":{"project":"demo","topic":"reverse proxies"}}')
echo "$CONV_RESPONSE" | jq .
CONV_ID=$(echo "$CONV_RESPONSE" | jq -r '.id')

if [ "$CONV_ID" = "null" ] || [ -z "$CONV_ID" ]; then
    printf "\n\033[1;31mError: no conversation ID returned.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mConversation ID: %s\033[0m\n" "$CONV_ID"
sleep 3

# ── Step 2: Turn 1 — send with conversation field ───────────────────

banner "2. Turn 1 — first message with conversation field"
printf "Send a Responses API request with \"conversation\": \"%s\".\n" "$CONV_ID"
printf "Since the conversation is empty, only our new input is sent\n"
printf "to vLLM. After the response, Praxis automatically appends\n"
printf "both input and output items back to the conversation.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"My name is Seb and I build reverse proxies. Remember this.","conversation":"'"$CONV_ID"'"}'\'' | jq .'
type_cmd "$CMD"
RESPONSE1=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"My name is Seb and I build reverse proxies. Remember this.","conversation":"'"$CONV_ID"'"}')
echo "$RESPONSE1" | jq .
TOKENS_1=$(echo "$RESPONSE1" | jq -r '.usage.total_tokens')

printf "\n\033[1;33m↳ total_tokens: %s\033[0m\n" "$TOKENS_1"
printf "\033[1;33m  Items auto-appended to conversation.\033[0m\n"
sleep 3

# ── Step 3: Check conversation items ────────────────────────────────

banner "3. Verify — items appended automatically"
printf "List the conversation items. Praxis appended the user input\n"
printf "and assistant output after the successful response.\n"
sleep 1

CMD="curl -s \"$PRAXIS/v1/conversations/$CONV_ID/items?order=asc\" | jq ."
type_cmd "$CMD"
sleep 1
ITEMS=$(curl -s "$PRAXIS/v1/conversations/$CONV_ID/items?order=asc")
echo "$ITEMS" | jq .
ITEM_COUNT=$(echo "$ITEMS" | jq '.data | length')
printf "\n\033[1;33m↳ %s items in conversation (input + output from turn 1)\033[0m\n" "$ITEM_COUNT"
sleep 3

# ── Step 4: Turn 2 — rehydrated from conversation ───────────────────

banner "4. Turn 2 — rehydrated from conversation history"
printf "Send another request with the same conversation ID.\n"
printf "Praxis rehydrates: loads the stored items, prepends them\n"
printf "to the input, and rebuilds the body before forwarding.\n"
printf "The conversation field is stripped from the outbound request.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"What is my name and what do I build?","conversation":"'"$CONV_ID"'"}'\'' | jq .'
type_cmd "$CMD"
RESPONSE2=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"What is my name and what do I build?","conversation":"'"$CONV_ID"'"}')
echo "$RESPONSE2" | jq .
TOKENS_2=$(echo "$RESPONSE2" | jq -r '.usage.total_tokens')
ANSWER=$(echo "$RESPONSE2" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

printf "\n\033[1;33m↳ total_tokens: %s (turn 1 was %s)\033[0m\n" "$TOKENS_2" "$TOKENS_1"
printf "\033[1;33m  More tokens = conversation history was included.\033[0m\n"
if [ -n "$ANSWER" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER"
    printf "\033[1;32m  It remembers! Conversation rehydration worked.\033[0m\n"
fi
sleep 3

# ── Step 5: Verify — items grew ─────────────────────────────────────

banner "5. Verify — conversation grew with turn 2"
printf "List items again. Turn 2's input and output were also\n"
printf "appended automatically — the conversation grows over time.\n"
sleep 1

CMD="curl -s \"$PRAXIS/v1/conversations/$CONV_ID/items?order=asc\" | jq ."
type_cmd "$CMD"
sleep 1
ITEMS2=$(curl -s "$PRAXIS/v1/conversations/$CONV_ID/items?order=asc")
echo "$ITEMS2" | jq .
ITEM_COUNT_2=$(echo "$ITEMS2" | jq '.data | length')
printf "\n\033[1;33m↳ %s items now (was %s after turn 1)\033[0m\n" "$ITEM_COUNT_2" "$ITEM_COUNT"
sleep 3

# ── Step 6: SQLite verification ─────────────────────────────────────

banner "6. SQLite — conversation items in the database"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/responses.db"

type_cmd "sqlite3 $DB \"SELECT item_id, json_extract(item_data, '$.role') as role, substr(json_extract(item_data, '$.content'), 1, 60) as content FROM openai_conversation_items WHERE conversation_id='$CONV_ID' ORDER BY position;\""
sqlite3 "$DB" "SELECT item_id, json_extract(item_data, '$.role') as role, substr(json_extract(item_data, '$.content'), 1, 60) as content FROM openai_conversation_items WHERE conversation_id='$CONV_ID' ORDER BY position;" 2>/dev/null || \
    printf "\033[1;31mCould not query database.\033[0m\n"
sleep 3

printf "\n\033[1;32mDone.\033[0m Conversations grow automatically — Praxis appends\n"
printf "input+output items after each successful response. The client\n"
printf "only needs to send the conversation ID, not the full history.\n"
sleep 3
