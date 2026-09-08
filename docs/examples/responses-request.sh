#!/usr/bin/env bash
# A subordinate completion worker, not a retry queue or a shell-code executor.
set -uo pipefail
if [[ "$#" -lt 2 || "$#" -gt 3 || "${1:-}" == --help ]]; then
    echo 'Usage: responses-request.sh NEW_OUTPUT_DIR INPUT_ITEMS_JSON [CREATE_BODY_JSON]'
    echo 'Makes one paid inference request when given arguments. Configure provider/key/model in the environment.'
    exit 0
fi
command -v llm >/dev/null || { echo 'Put Headlong bin/ on PATH first' >&2; exit 2; }
jq -e 'type == "array"' "$2" >/dev/null || exit 2
if [[ "$#" == 3 ]]; then
    jq -e 'type == "object"' "$3" >/dev/null || exit 2
    export LLM_RESPONSES_BODY_FILE="$3"
fi
umask 077
mkdir -- "$1" || { echo 'Use a new output directory; existing evidence is not overwritten' >&2; exit 2; }
out=$(cd "$1" && pwd)
export LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$out/response.json"
export LLM_USAGE_FILE="$out/usage.json"
child=""; interrupted=0
trap 'interrupted=1; [[ -z "$child" ]] || kill -TERM "$child" 2>/dev/null || true' INT TERM
llm -m "${LLM_MODEL:-gpt-5.4-mini}" --no-stream --messages-file "$2" \
    > "$out/stdout.txt" 2> "$out/stderr.txt" &
child=$!
rc=0
wait "$child" || rc=$?
if [[ "$interrupted" == 1 ]]; then
    wait "$child" 2>/dev/null || true
    rc=1
fi
child=""
trap - INT TERM
# Exit success is not sufficient: require a complete application result.
if [[ "$rc" == 0 ]] && jq -e '.status == "completed" and .error == null
    and (.id | type == "string" and length > 0) and (.output | type == "array")' \
    "$out/response.json" >/dev/null 2>&1; then
    outcome=completed
else
    outcome=needs_review
    [[ "$rc" != 0 ]] || rc=1
fi
jq -n --arg outcome "$outcome" --argjson exit_code "$rc" \
    '{outcome:$outcome,exit_code:$exit_code}' > "$out/outcome.json"
cat "$out/outcome.json"
exit "$rc"
