#!/usr/bin/env bash
set -euo pipefail

NUM_REQUESTS=10
MAX_TOKENS=1024

PROMPTS=(
    "Write a detailed tutorial on implementing a binary search tree in Python with insert, delete, and search operations."
    "Explain the differences between TCP and UDP protocols, including use cases, advantages, and disadvantages of each."
    "Write a Python script that reads a CSV file, performs data cleaning, and outputs summary statistics."
    "Describe the architecture of a modern web application, covering frontend, backend, database, and deployment layers."
    "Implement a simple HTTP server in Python from scratch using only the socket library, with GET and POST support."
    "Write a comprehensive guide to SQL joins with examples: inner join, left join, right join, full outer join, and cross join."
    "Explain how garbage collection works in Java, covering generational GC, G1, and ZGC collectors."
    "Write a Python implementation of common sorting algorithms: quicksort, mergesort, heapsort, and compare their complexities."
    "Describe the CAP theorem in distributed systems and explain how different databases make trade-offs between consistency, availability, and partition tolerance."
    "Write a REST API design guide covering resource naming, HTTP methods, status codes, pagination, and error handling."
)

SERVER_A="http://localhost:9000/v1/completions"
MODEL_A="laguna"

SERVER_B="http://localhost:9001/v1/completions"
MODEL_B="poolside/Laguna-XS.2"

measure_itl() {
    local url=$1 model=$2 prompt=$3
    local payload
    payload=$(jq -n \
        --arg model "$model" \
        --arg prompt "$prompt" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{model: $model, prompt: $prompt, max_tokens: $max_tokens, temperature: 0.7, stream: true, logprobs: 1}')

    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f $tmpfile" RETURN

    # Capture each SSE data chunk with a high-res timestamp
    while IFS= read -r line; do
        if [[ "$line" == data:* ]]; then
            local data="${line#data: }"
            [[ "$data" == "[DONE]" ]] && continue
            local ts
            ts=$(date +%s%N)
            # Count tokens via logprobs.tokens array length; fall back to 1
            local n_tokens
            n_tokens=$(echo "$data" | jq '.choices[0].logprobs.tokens | length // 1' 2>/dev/null || echo 1)
            [[ "$n_tokens" -eq 0 ]] && n_tokens=1
            echo "$ts $n_tokens" >> "$tmpfile"
        fi
    done < <(curl -s -N "$url" -H "Content-Type: application/json" -d "$payload" 2>/dev/null)

    local n_chunks
    n_chunks=$(wc -l < "$tmpfile")
    if [[ "$n_chunks" -lt 2 ]]; then
        echo "ERROR 0 0 0"
        return
    fi

    # Read all timestamps and token counts into arrays
    local -a timestamps=() token_counts=()
    while read -r ts tc; do
        timestamps+=("$ts")
        token_counts+=("$tc")
    done < "$tmpfile"

    # TTFT = first chunk arrival minus nothing (we only have chunk times, so skip)
    # ITL: for each gap between consecutive chunks, compute per-token latency
    #   gap_ms / n_tokens_in_later_chunk = per-token ITL for that chunk
    local total_itl_ns=0 total_tokens=0
    for (( i=1; i<${#timestamps[@]}; i++ )); do
        local gap_ns=$(( ${timestamps[$i]} - ${timestamps[$i-1]} ))
        local toks=${token_counts[$i]}
        # Per-token ITL for this chunk = gap / tokens_in_chunk
        # We accumulate weighted: total_gap and total_tokens, then avg = total_gap / total_tokens
        total_itl_ns=$((total_itl_ns + gap_ns))
        total_tokens=$((total_tokens + toks))
    done

    if [[ "$total_tokens" -eq 0 ]]; then
        echo "ERROR 0 0 0"
        return
    fi

    local ttft_ms avg_itl_ms
    ttft_ms=$(awk "BEGIN {printf \"%.2f\", (${timestamps[1]} - ${timestamps[0]}) / 1000000.0}")
    avg_itl_ms=$(awk "BEGIN {printf \"%.2f\", $total_itl_ns / $total_tokens / 1000000.0}")

    # Total tokens = first chunk tokens + subsequent tokens
    local all_tokens=$(( ${token_counts[0]} + total_tokens ))
    echo "$avg_itl_ms $ttft_ms $all_tokens $n_chunks"
}

benchmark_server() {
    local label=$1 url=$2 model=$3
    local sum_itl=0 sum_ttft=0 successful=0

    echo "--- $label ---"
    printf "  %-10s %10s %10s %8s %8s\n" "request" "avg ITL" "TTFT" "tokens" "chunks"
    printf "  %-10s %10s %10s %8s %8s\n" "-------" "-------" "----" "------" "------"

    for i in $(seq 1 "$NUM_REQUESTS"); do
        local prompt="${PROMPTS[$((i-1))]}"
        read -r avg_itl ttft total_tokens n_chunks <<< "$(measure_itl "$url" "$model" "$prompt")"
        if [[ "$avg_itl" == "ERROR" ]]; then
            printf "  %-10s %10s\n" "$i" "FAILED"
            continue
        fi
        successful=$((successful + 1))
        sum_itl=$(awk "BEGIN {printf \"%.4f\", $sum_itl + $avg_itl}")
        sum_ttft=$(awk "BEGIN {printf \"%.4f\", $sum_ttft + $ttft}")
        printf "  %-10d %8s ms %8s ms %8s %8s\n" "$i" "$avg_itl" "$ttft" "$total_tokens" "$n_chunks"
    done

    if [[ "$successful" -eq 0 ]]; then
        echo "  No successful requests."
        echo "0 0"
        return
    fi

    local overall_itl overall_ttft
    overall_itl=$(awk "BEGIN {printf \"%.2f\", $sum_itl / $successful}")
    overall_ttft=$(awk "BEGIN {printf \"%.2f\", $sum_ttft / $successful}")
    printf "\n  mean ITL:  %s ms/token\n" "$overall_itl"
    printf "  mean TTFT: %s ms\n" "$overall_ttft"
    printf "  (%d/%d requests succeeded)\n\n" "$successful" "$NUM_REQUESTS"
    echo "$overall_itl $overall_ttft"
}

echo "Measuring inter-token latency ($NUM_REQUESTS sequential requests, max_tokens=$MAX_TOKENS)"
echo "Using logprobs to count actual tokens per SSE chunk (handles speculative decoding bursts)"
echo ""

result_a=$(benchmark_server "Server A — port 9000 (model=$MODEL_A)" "$SERVER_A" "$MODEL_A")
itl_a=$(echo "$result_a" | tail -1 | awk '{print $1}')
ttft_a=$(echo "$result_a" | tail -1 | awk '{print $2}')
echo "$result_a" | head -n -1

result_b=$(benchmark_server "Server B — port 9001 (model=$MODEL_B)" "$SERVER_B" "$MODEL_B")
itl_b=$(echo "$result_b" | tail -1 | awk '{print $1}')
ttft_b=$(echo "$result_b" | tail -1 | awk '{print $2}')
echo "$result_b" | head -n -1

echo "========================================="
printf "Server A:  ITL = %s ms/token,  TTFT = %s ms\n" "$itl_a" "$ttft_a"
printf "Server B:  ITL = %s ms/token,  TTFT = %s ms\n" "$itl_b" "$ttft_b"
echo ""
itl_winner=$(awk "BEGIN {if ($itl_a < $itl_b) print \"A (port 9000)\"; else if ($itl_b < $itl_a) print \"B (port 9001)\"; else print \"TIE\"}")
ttft_winner=$(awk "BEGIN {if ($ttft_a < $ttft_b) print \"A (port 9000)\"; else if ($ttft_b < $ttft_a) print \"B (port 9001)\"; else print \"TIE\"}")
echo "Lower ITL:  Server $itl_winner"
echo "Lower TTFT: Server $ttft_winner"
