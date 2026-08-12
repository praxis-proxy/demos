#!/usr/bin/env bash
# Demo runner — file search via vector store callout.
set -uo pipefail

PRAXIS="http://127.0.0.1:8080"
OGX="http://127.0.0.1:8321"
MODEL="Qwen/Qwen3-0.6B"
EMBEDDING_MODEL="sentence-transformers/nomic-ai/nomic-embed-text-v1.5"
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

# ── Step 1: Create a vector store in OGX ──────────────────────────────

banner "1. Create a vector store in OGX"
printf "Create a FAISS-backed vector store in OGX for\n"
printf "semantic search over uploaded documents.\n"
sleep 1

CMD="curl -s $OGX/v1/vector_stores -H 'Content-Type: application/json' -d '{\"name\":\"praxis-demo\",\"embedding_model\":\"$EMBEDDING_MODEL\",\"embedding_dimension\":768,\"provider_id\":\"faiss\"}' | jq ."
type_cmd "$CMD"
VS_RESPONSE=$(curl -s "$OGX/v1/vector_stores" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"praxis-demo\",\"embedding_model\":\"$EMBEDDING_MODEL\",\"embedding_dimension\":768,\"provider_id\":\"faiss\"}")
echo "$VS_RESPONSE" | jq . 2>/dev/null || echo "$VS_RESPONSE"
STORE_ID=$(echo "$VS_RESPONSE" | jq -r '.id' 2>/dev/null || echo "")

if [ "$STORE_ID" = "null" ] || [ -z "$STORE_ID" ]; then
    printf "\n\033[1;31mError: no vector store ID returned. Check OGX.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mVector Store ID: %s\033[0m\n" "$STORE_ID"
sleep 3

# ── Step 2: Upload a file and attach to the vector store ─────────────

banner "2. Upload a file and attach to the vector store"
printf "Upload a document to OGX, then attach it to the\n"
printf "vector store for indexing and semantic search.\n"
sleep 1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_FILE="$SCRIPT_DIR/sample-doc.txt"

CMD="curl -s $OGX/v1/files -F purpose=assistants -F 'file=@sample-doc.txt' | jq ."
type_cmd "$CMD"
UPLOAD_RESPONSE=$(curl -s "$OGX/v1/files" \
    -F purpose=assistants \
    -F "file=@$SAMPLE_FILE")
echo "$UPLOAD_RESPONSE" | jq . 2>/dev/null || echo "$UPLOAD_RESPONSE"
FILE_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.id' 2>/dev/null || echo "")

if [ "$FILE_ID" = "null" ] || [ -z "$FILE_ID" ]; then
    printf "\n\033[1;31mError: no file_id returned. Check OGX.\033[0m\n"
    sleep 3
    exit 1
fi

printf "\n\033[1;33mFile ID: %s\033[0m\n" "$FILE_ID"
sleep 1

CMD="curl -s $OGX/v1/vector_stores/$STORE_ID/files -H 'Content-Type: application/json' -d '{\"file_id\":\"$FILE_ID\"}' | jq ."
type_cmd "$CMD"
ATTACH_RESPONSE=$(curl -s "$OGX/v1/vector_stores/$STORE_ID/files" \
    -H "Content-Type: application/json" \
    -d "{\"file_id\":\"$FILE_ID\"}")
echo "$ATTACH_RESPONSE" | jq . 2>/dev/null || echo "$ATTACH_RESPONSE"
sleep 1

printf "\n\033[1;33mWaiting for indexing..."
for i in $(seq 1 60); do
    STATUS=$(curl -s "$OGX/v1/vector_stores/$STORE_ID/files/$FILE_ID" | jq -r '.status' 2>/dev/null || echo "")
    if [ "$STATUS" = "completed" ]; then
        printf " done.\033[0m\n"
        break
    fi
    if [ "$STATUS" = "failed" ] || [ "$STATUS" = "cancelled" ]; then
        printf " %s.\033[0m\n" "$STATUS"
        break
    fi
    printf "."
    sleep 1
done
sleep 2

# ── Step 3: File search — ask about request volume ───────────────────

banner "3. File search — ask about request volume"
printf "Send a Responses API request with a file_search tool.\n"
printf "The model calls file_search, Praxis dispatches to OGX's\n"
printf "vector store search, loops back with results, model answers.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Use the file_search tool to find how many API requests Praxis processed. Report the exact number. /no_think","tools":[{"type":"file_search","vector_store_ids":["'"$STORE_ID"'"]}],"include":["file_search_call.results"],"store":false,"max_output_tokens":512}'\'' | jq .'
type_cmd "$CMD"
RESPONSE=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"Use the file_search tool to find how many API requests Praxis processed. Report the exact number. /no_think","tools":[{"type":"file_search","vector_store_ids":["'"$STORE_ID"'"]}],"include":["file_search_call.results"],"store":false,"max_output_tokens":512}')
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

FS_ITEMS=$(echo "$RESPONSE" | jq '[.output[] | select(.type == "file_search_call")]' 2>/dev/null || echo "[]")
FS_COUNT=$(echo "$FS_ITEMS" | jq 'length' 2>/dev/null || echo "0")
ANSWER=$(echo "$RESPONSE" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

if [ "$FS_COUNT" -gt 0 ]; then
    printf "\n\033[1;33m↳ %s file_search_call(s) executed by Praxis.\033[0m\n" "$FS_COUNT"
fi
if [ -n "$ANSWER" ]; then
    printf "\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER"
fi
sleep 3

# ── Step 4: File search — ask about security ─────────────────────────

banner "4. File search — ask about security measures"
printf "Different question, same vector store. Praxis loops again.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Use the file_search tool to find what security measures Praxis uses. Be specific. /no_think","tools":[{"type":"file_search","vector_store_ids":["'"$STORE_ID"'"]}],"include":["file_search_call.results"],"store":false,"max_output_tokens":512}'\'' | jq .'
type_cmd "$CMD"
RESPONSE2=$(curl -s "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"Use the file_search tool to find what security measures Praxis uses. Be specific. /no_think","tools":[{"type":"file_search","vector_store_ids":["'"$STORE_ID"'"]}],"include":["file_search_call.results"],"store":false,"max_output_tokens":512}')
echo "$RESPONSE2" | jq . 2>/dev/null || echo "$RESPONSE2"

ANSWER2=$(echo "$RESPONSE2" | jq -r '.output[] | select(.type == "message") | .content[] | select(.type == "output_text") | .text' 2>/dev/null || echo "")

if [ -n "$ANSWER2" ]; then
    printf "\n\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER2"
fi
sleep 3

# ── Cleanup ──────────────────────────────────────────────────────────

banner "5. Cleanup"
printf "Delete the vector store and uploaded file.\n"
sleep 1

CMD="curl -s -X DELETE $OGX/v1/vector_stores/$STORE_ID | jq ."
type_cmd "$CMD"
curl -s -X DELETE "$OGX/v1/vector_stores/$STORE_ID" | jq . 2>/dev/null || true

CMD="curl -s -X DELETE $OGX/v1/files/$FILE_ID | jq ."
type_cmd "$CMD"
curl -s -X DELETE "$OGX/v1/files/$FILE_ID" | jq . 2>/dev/null || true
sleep 1

printf "\n\033[1;32mDone.\033[0m Praxis executed file_search_call via OGX vector\n"
printf "store search, fed results back to the model as context,\n"
printf "and produced answers with citations. No client-side RAG needed.\n"
sleep 3
