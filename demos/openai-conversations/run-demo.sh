#!/usr/bin/env bash
# Demo runner — OpenAI Conversations API CRUD lifecycle.
# No backend needed — all requests are handled locally by Praxis.
set -euo pipefail

PRAXIS="http://127.0.0.1:8080"
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

# ── Step 1: Create ──────────────────────────────────────────────────

banner "1. Create a conversation"
printf "POST /v1/conversations with metadata. Praxis handles it locally\n"
printf "and stores it in SQLite — nothing is forwarded upstream.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/conversations -H "Content-Type: application/json" -d '\''{"metadata":{"project":"praxis-demo","env":"staging"},"items":[{"type":"message","role":"user","content":"What is a reverse proxy?"}]}'\'' | jq .'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/conversations \
    -H "Content-Type: application/json" \
    -d '{"metadata":{"project":"praxis-demo","env":"staging"},"items":[{"type":"message","role":"user","content":"What is a reverse proxy?"}]}')
echo "$RESPONSE" | jq .
CONV_ID=$(echo "$RESPONSE" | jq -r '.id')

if [ "$CONV_ID" = "null" ] || [ -z "$CONV_ID" ]; then
    printf "\n\033[1;31mError: no conversation ID returned.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mConversation ID: %s\033[0m\n" "$CONV_ID"
sleep 3

# ── Step 2: Retrieve ────────────────────────────────────────────────

banner "2. Retrieve the conversation"
printf "GET /v1/conversations/{id} — fetch it back.\n"
sleep 1

CMD="curl -s $PRAXIS/v1/conversations/$CONV_ID | jq ."
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID" | jq .
sleep 3

# ── Step 3: Add an assistant reply ─────────────────────────────────

banner "3. Add an assistant reply"
printf "POST an assistant message item to the conversation.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/conversations/'"$CONV_ID"'/items -H "Content-Type: application/json" -d '\''{"items":[{"type":"message","role":"assistant","content":"A server that sits in front of backends and forwards client requests to them."}]}'\'' | jq .'
type_cmd "$CMD"
ITEM_RESP=$(curl -s "$PRAXIS/v1/conversations/$CONV_ID/items" \
    -H "Content-Type: application/json" \
    -d '{"items":[{"type":"message","role":"assistant","content":"A server that sits in front of backends and forwards client requests to them."}]}')
echo "$ITEM_RESP" | jq .
ITEM_ID=$(echo "$ITEM_RESP" | jq -r '.data[0].id')
printf "\n\033[1;33mItem ID: %s\033[0m\n" "$ITEM_ID"
sleep 3

# ── Step 4: List items ─────────────────────────────────────────────

banner "4. List conversation items"
printf "GET /v1/conversations/{id}/items — both messages are stored.\n"
sleep 1

CMD="curl -s '$PRAXIS/v1/conversations/$CONV_ID/items?order=asc' | jq ."
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID/items?order=asc" | jq .
sleep 3

# ── Step 5: Get a single item ──────────────────────────────────────

banner "5. Retrieve a single item"
printf "GET /v1/conversations/{id}/items/{item_id} — fetch one item.\n"
sleep 1

CMD="curl -s $PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID | jq ."
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID" | jq .
sleep 3

# ── Step 6: Update metadata ────────────────────────────────────────

banner "6. Update conversation metadata"
printf "POST /v1/conversations/{id} — promote from staging to production.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/conversations/'"$CONV_ID"' -H "Content-Type: application/json" -d '\''{"metadata":{"project":"praxis-demo","env":"production"}}'\'' | jq .'
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID" \
    -H "Content-Type: application/json" \
    -d '{"metadata":{"project":"praxis-demo","env":"production"}}' | jq .
sleep 3

# ── Step 7: Delete an item ─────────────────────────────────────────

banner "7. Delete the assistant item"
printf "DELETE /v1/conversations/{id}/items/{item_id} — remove one item.\n"
sleep 1

CMD="curl -s -X DELETE $PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID | jq ."
type_cmd "$CMD"
curl -s -X DELETE "$PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID" | jq .
sleep 2

printf "\nVerify it's gone:\n"
CMD="curl -s $PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID | jq ."
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID/items/$ITEM_ID" | jq .
sleep 3

# ── Step 8: Delete the conversation ────────────────────────────────

banner "8. Delete the conversation"
printf "DELETE /v1/conversations/{id} — soft-delete the conversation.\n"
printf "Items are preserved for audit.\n"
sleep 1

CMD="curl -s -X DELETE $PRAXIS/v1/conversations/$CONV_ID | jq ."
type_cmd "$CMD"
curl -s -X DELETE "$PRAXIS/v1/conversations/$CONV_ID" | jq .
sleep 2

printf "\nVerify it's gone:\n"
CMD="curl -s $PRAXIS/v1/conversations/$CONV_ID | jq ."
type_cmd "$CMD"
curl -s "$PRAXIS/v1/conversations/$CONV_ID" | jq .
sleep 3

# ── Step 9: SQLite verification ────────────────────────────────────

banner "9. Verify — SQLite store"
printf "The initial user item survives conversation deletion.\n"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB="$SCRIPT_DIR/conversations.db"

type_cmd "sqlite3 $DB \"SELECT item_id, json_extract(item_data, '\$.role') as role, json_extract(item_data, '\$.content[0].text') as text FROM openai_conversation_items WHERE conversation_id='$CONV_ID' ORDER BY position;\""
sqlite3 "$DB" "SELECT item_id, json_extract(item_data, '$.role') as role, json_extract(item_data, '$.content[0].text') as text FROM openai_conversation_items WHERE conversation_id='$CONV_ID' ORDER BY position;" 2>/dev/null || \
    printf "\033[1;31mCould not query database.\033[0m\n"
sleep 2

printf "\n\033[1;33m↳ The user item is still in the database.\033[0m\n"
printf "\033[1;33m  The assistant item was deleted in step 7.\033[0m\n"
printf "\033[1;33m  The conversation row was soft-deleted in step 8.\033[0m\n"
sleep 3

printf "\n\033[1;32mDone.\033[0m Full conversation lifecycle — create with initial items,\n"
printf "retrieve, add items, list, get single item, update metadata,\n"
printf "delete item, delete conversation — all handled locally by Praxis\n"
printf "with zero upstream traffic.\n"
sleep 3
