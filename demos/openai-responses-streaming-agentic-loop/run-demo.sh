#!/usr/bin/env bash
# Demo runner — streaming agentic loop, SSE across IRR rounds.
set -uo pipefail

PRAXIS="http://127.0.0.1:8080"
MCP_URL="http://127.0.0.1:9100/mcp"
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

# Summarize a streamed SSE capture: count lifecycle events and show
# that one logical stream spans however many rounds happened.
stream_summary() {
    local tmp="$1"
    local created completed deltas fc_deltas
    created=$(grep -c 'event: response.created' "$tmp" 2>/dev/null || echo 0)
    completed=$(grep -c 'event: response.completed' "$tmp" 2>/dev/null || echo 0)
    deltas=$(grep -c 'event: response.output_text.delta' "$tmp" 2>/dev/null || echo 0)
    fc_deltas=$(grep -c 'event: response.function_call_arguments.delta' "$tmp" 2>/dev/null || echo 0)
    printf "\n\033[1;33m↳ SSE lifecycle: response.created=%s  response.completed=%s\033[0m\n" \
        "$created" "$completed"
    printf "\033[1;33m  output_text.delta=%s  function_call_arguments.delta=%s\033[0m\n" \
        "$deltas" "$fc_deltas"
    if [ "$created" = "1" ] && [ "$completed" = "1" ]; then
        printf "\033[1;32m  One logical stream — created/completed exactly once across all rounds.\033[0m\n"
    fi
}

# Extract the final answer text from a streamed SSE capture.
stream_answer() {
    local tmp="$1"
    grep 'data: ' "$tmp" \
        | sed 's/^data: //' \
        | jq -r 'select(.type == "response.completed") | .response.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text' \
        2>/dev/null | tail -1 || echo ""
}

sleep 2

# ── Step 1: Simple streaming (no tools) ───────────────────────────────

banner "1. Simple streaming — no tools, single round"
printf "Send stream=true with no tools. SSE events flow through the\n"
printf "IRR terminal-streaming transport in real time. One round:\n"
printf "response.created ... output_text.delta ... response.completed.\n"
sleep 1

CMD='curl -sN '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Say hello in one short sentence.","stream":true}'\'''
type_cmd "$CMD"
TMP1=$(mktemp)
curl -sN "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"Say hello in one short sentence.","stream":true}' \
    | tee "$TMP1"
stream_summary "$TMP1"
rm -f "$TMP1"
sleep 3

# ── Step 2: Streaming + web search (Tavily) ───────────────────────────

banner "2. Streaming + web search — multi-round, one logical stream"
printf "Send stream=true with a web_search tool. The model calls\n"
printf "web_search (round 1, streamed), Praxis dispatches to Tavily,\n"
printf "then streams the grounded answer (round 2). The client sees\n"
printf "ONE logical stream — created/completed exactly once.\n"
sleep 1

CMD='curl -sN '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Search the web: what is Praxis proxy? One sentence. /no_think","stream":true,"tools":[{"type":"web_search"}]}'\'''
type_cmd "$CMD"
TMP2=$(mktemp)
curl -sN "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"Search the web: what is Praxis proxy? One sentence. /no_think","stream":true,"tools":[{"type":"web_search"}]}' \
    | tee "$TMP2"
stream_summary "$TMP2"
ANSWER2=$(stream_answer "$TMP2")
if [ -n "$ANSWER2" ]; then
    printf "\033[1;32m↳ Grounded answer:\033[0m %s\n" "$ANSWER2"
fi
rm -f "$TMP2"
sleep 3

# ── Step 3: Streaming + MCP tool call ─────────────────────────────────

banner "3. Streaming + MCP tool call — multi-round, one logical stream"
printf "Send stream=true with an MCP weather tool. Round 1 streams the\n"
printf "tool call, Praxis dispatches to the MCP server, round 2 streams\n"
printf "the final answer — all one logical stream.\n"
sleep 1

CMD='curl -sN '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"What is the weather in San Francisco? /no_think","stream":true,"tools":[{"type":"mcp","server_label":"weather","server_url":"'"$MCP_URL"'","allowed_tools":["get_weather"],"require_approval":"never"}]}'\'''
type_cmd "$CMD"
TMP3=$(mktemp)
curl -sN "$PRAXIS"/v1/responses \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$MODEL"'","input":"What is the weather in San Francisco? /no_think","stream":true,"tools":[{"type":"mcp","server_label":"weather","server_url":"'"$MCP_URL"'","allowed_tools":["get_weather"],"require_approval":"never"}]}' \
    | tee "$TMP3"
stream_summary "$TMP3"
ANSWER3=$(stream_answer "$TMP3")
if [ -n "$ANSWER3" ]; then
    printf "\033[1;32m↳ Model answered:\033[0m %s\n" "$ANSWER3"
fi
rm -f "$TMP3"
sleep 3

printf "\n\033[1;32mDone.\033[0m Every round streamed through the same Responses SSE\n"
printf "lifecycle. stream_events (logical_stream) held each round's terminal\n"
printf "event until the loop decision was known, so the client saw one\n"
printf "continuous stream — created and completed exactly once.\n"
sleep 3
