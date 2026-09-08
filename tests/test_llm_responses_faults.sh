#!/usr/bin/env bash
# Synchronous completion faults shared with the limited upstream integration.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf 'create\n' >> "$CALLS"
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" != -o ]] || out="$arg"
    prev="$arg"
done
case "$MODE" in
    lost) exit 28 ;;
    http500) printf '{"error":{"message":"internal"}}' > "$out"; printf 500 ;;
    lost-id) printf '{"id":"resp_a","status":"in_progress"}' > "$out"; exit 28 ;;
    malformed) printf '{' > "$out"; printf 200 ;;
    empty) printf ' \n' > "$out"; printf 200 ;;
    unknown) printf '{"id":"resp_a","status":"new_status","output":[]}' > "$out"; printf 200 ;;
    cancelled|failed)
        printf '{"id":"resp_a","status":"%s","output":[]}' "$MODE" > "$out"; printf 200 ;;
    embedded) printf '{"id":"resp_a","status":"completed","error":{"message":"broken"},"output":[]}' > "$out"; printf 200 ;;
    stream-empty) : ;;
    stream-lost)
        printf 'data: {"type":"response.created","response":{"id":"resp_a","status":"in_progress"}}\n\n'
        ;;
    stream-cancelled|stream-failed)
        status="${MODE#stream-}"
        printf 'data: {"type":"response.%s","response":{"id":"resp_a","status":"%s","output":[]}}\n\n' "$status" "$status"
        ;;
    stream-malformed)
        printf 'data: {"type":"response.completed","response":{"status":"completed"}}\n\n'
        ;;
    stream-mismatch)
        printf 'data: {"type":"response.completed","response":{"id":"resp_a","status":"incomplete","output":[]}}\n\n'
        ;;
    stream-identity)
        printf 'data: {"type":"response.created","response":{"id":"resp_a","status":"in_progress"}}\n\n'
        printf 'data: {"type":"response.completed","response":{"id":"resp_b","status":"completed","output":[]}}\n\n'
        ;;
esac
STUB
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH" HEADLONG_HOME="$WORK/home" OPENAI_API_KEY=test-key
export LLM_API_FORMAT=responses LLM_RETRIES=3 LLM_RETRY_BACKOFF=0
export LLM_RESPONSE_FILE="$WORK/response" CALLS="$WORK/calls"
pass=0; fail=0
for MODE in lost lost-id http500 malformed empty unknown cancelled failed embedded stream-empty stream-lost stream-cancelled stream-failed stream-malformed stream-mismatch stream-identity; do
    export MODE
    rm -f "$CALLS" "$LLM_RESPONSE_FILE"
    args=(--no-stream)
    [[ "$MODE" != stream-* ]] || args=()
    "$REPO/bin/llm" --provider openai -m gpt-5.4-mini "${args[@]+"${args[@]}"}" test >"$WORK/out" 2>"$WORK/err"
    rc=$?
    if [[ "$rc" -ne 0 && "$(wc -l < "$CALLS" | tr -d ' ')" == 1 && ! -s "$WORK/out" ]]; then
        printf 'ok   %s fails with exactly one create\n' "$MODE"; pass=$((pass+1))
    else
        printf 'FAIL %s rc=%s: %s\n' "$MODE" "$rc" "$(cat "$WORK/err")"; fail=$((fail+1))
    fi
    case "$MODE" in
        cancelled|failed|embedded|stream-cancelled|stream-failed) continue ;;
    esac
    if jq -e '.error.code == "outcome_unknown"' "$LLM_RESPONSE_FILE" >/dev/null 2>&1; then
        printf 'ok   %s preserves typed unknown outcome\n' "$MODE"; pass=$((pass+1))
    else
        printf 'FAIL %s missing unknown outcome sidecar\n' "$MODE"; fail=$((fail+1))
    fi
    case "$MODE" in
        stream-lost|lost-id|unknown)
            if jq -e '.id == "resp_a"' "$LLM_RESPONSE_FILE" >/dev/null; then
                printf 'ok   %s preserves known response handle\n' "$MODE"; pass=$((pass+1))
            else
                printf 'FAIL %s discarded known response handle\n' "$MODE"; fail=$((fail+1))
            fi ;;
    esac
done
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
