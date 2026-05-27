#!/usr/bin/env bash
set -euo pipefail

NUM_REQUESTS=5
MAX_TOKENS=200
PROMPT="Write a short function in Python that computes the Fibonacci sequence iteratively."

SERVER_A="http://localhost:9000/v1/completions"
MODEL_A="laguna"

SERVER_B="http://localhost:9001/v1/completions"
MODEL_B="poolside/Laguna-XS.2"

send_request() {
    local url=$1 model=$2
    local payload
    payload=$(jq -n \
        --arg model "$model" \
        --arg prompt "$PROMPT" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{model: $model, prompt: $prompt, max_tokens: $max_tokens, temperature: 0.7}')

    local start end elapsed
    start=$(date +%s%N)
    local resp
    resp=$(curl -s "$url" -H "Content-Type: application/json" -d "$payload")
    end=$(date +%s%N)
    elapsed=$(( (end - start) / 1000000 ))

    local tokens
    tokens=$(echo "$resp" | jq '.usage.completion_tokens // 0')
    if [[ "$tokens" -eq 0 ]]; then
        echo "ERROR: no tokens returned. Response: $(echo "$resp" | head -c 200)" >&2
        echo "0 0"
        return
    fi

    echo "$tokens $elapsed"
}

benchmark_server() {
    local label=$1 url=$2 model=$3
    local total_tokens=0 total_ms=0 successful=0

    echo "--- $label ($url, model=$model) ---"
    for i in $(seq 1 "$NUM_REQUESTS"); do
        read -r tokens ms <<< "$(send_request "$url" "$model")"
        if [[ "$tokens" -gt 0 ]]; then
            total_tokens=$((total_tokens + tokens))
            total_ms=$((total_ms + ms))
            successful=$((successful + 1))
            local tps
            tps=$(awk "BEGIN {printf \"%.1f\", $tokens / ($ms / 1000.0)}")
            printf "  request %d: %d tokens in %d ms (%.1f tok/s)\n" "$i" "$tokens" "$ms" "$tps"
        else
            printf "  request %d: FAILED\n" "$i"
        fi
    done

    if [[ "$successful" -eq 0 ]]; then
        echo "  No successful requests."
        echo "0"
        return
    fi

    local avg_tps
    avg_tps=$(awk "BEGIN {printf \"%.2f\", $total_tokens / ($total_ms / 1000.0)}")
    printf "  avg throughput: %s tok/s (%d tokens in %d ms, %d/%d succeeded)\n\n" \
        "$avg_tps" "$total_tokens" "$total_ms" "$successful" "$NUM_REQUESTS"
    echo "$avg_tps"
}

echo "Sending $NUM_REQUESTS requests to each server (max_tokens=$MAX_TOKENS)..."
echo ""

result_a=$(benchmark_server "Server A (port 9000)" "$SERVER_A" "$MODEL_A")
avg_a=$(echo "$result_a" | tail -1)
echo "$result_a" | head -n -1

result_b=$(benchmark_server "Server B (port 9001)" "$SERVER_B" "$MODEL_B")
avg_b=$(echo "$result_b" | tail -1)
echo "$result_b" | head -n -1

echo "========================================="
printf "Server A avg: %s tok/s\n" "$avg_a"
printf "Server B avg: %s tok/s\n" "$avg_b"

winner=$(awk "BEGIN {if ($avg_a > $avg_b) print \"A (port 9000)\"; else if ($avg_b > $avg_a) print \"B (port 9001)\"; else print \"TIE\"}")
echo "Winner: Server $winner"
