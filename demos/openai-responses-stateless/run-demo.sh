#!/usr/bin/env bash
# Demo runner — curl commands in the bottom tmux pane.
# Praxis logs stream in the top pane (started by record.sh).
set -euo pipefail

PRAXIS="http://127.0.0.1:8080"
VLLM="http://127.0.0.1:8000"
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

banner "1. Direct to vLLM (no proxy)"
printf "Hit vLLM directly to confirm the backend works.\n"
sleep 1

CMD='curl -s '"$VLLM"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Why is Kubernetes awesome? Reply in one sentence.","store":false}'\'' | jq .'
type_cmd "$CMD"
eval "$CMD"
sleep 3

banner "2. Praxis → vLLM (stateless passthrough)"
printf "Same request through Praxis. store=false, no stateful markers.\n"
printf "The request is forwarded unchanged — zero additional processing.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Why is Kubernetes awesome? Reply in one sentence.","store":false}'\'' | jq .'
type_cmd "$CMD"
eval "$CMD"
sleep 3

banner "3. Praxis → vLLM (stateless passthrough, streaming)"
printf "Same passthrough with stream=true. SSE chunks forwarded as-is.\n"
sleep 1

CMD='curl -s '"$PRAXIS"'/v1/responses -H "Content-Type: application/json" -d '\''{"model":"'"$MODEL"'","input":"Why is Kubernetes awesome? Reply in one sentence.","store":false,"stream":true}'\'
type_cmd "$CMD"
eval "$CMD"
printf "\n"
sleep 3

printf "\n\033[1;32mDone.\033[0m Stateless requests bypass the stateful filter chain entirely.\n"
printf "Sub-millisecond proxy overhead, no buffering, no persistence.\n"
sleep 3
