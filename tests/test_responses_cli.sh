#!/usr/bin/env bash
# test_responses_cli.sh: bin/responses, the Responses lifecycle CLI.
# Hermetic: a curl stub on PATH records method, URL, body, and the auth
# config file, and replays canned JSON per CURL_MODE. Runs under bash 3.2.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=0
[[ -f "$CURL_CALLS" ]] && read -r n < "$CURL_CALLS"
n=$((n + 1))
printf '%s\n' "$n" > "$CURL_CALLS"
printf '%s\n' "$@" > "$CURL_ARGS"
method="GET"; out_file=""; payload_file=""; auth_file=""; url=""; prev=""
for arg in "$@"; do
    case "$prev" in
        -X) method="$arg" ;;
        -o) out_file="$arg" ;;
        -K) auth_file="$arg" ;;
        -d) [[ "$arg" == @* ]] && payload_file="${arg#@}" ;;
    esac
    case "$arg" in http://*|https://*) url="$arg" ;; esac
    prev="$arg"
done
printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
[[ -n "$payload_file" ]] && cp "$payload_file" "$CURL_PAYLOAD"
[[ -n "$auth_file" ]] && cp "$auth_file" "$CURL_AUTH"
emit() { if [[ -n "$out_file" ]]; then printf '%s' "$1" > "$out_file"; else printf '%s' "$1"; fi; }

case "$CURL_MODE" in
    response)
        emit '{"id":"resp_1","object":"response","status":"completed","output":[]}'
        printf '200'
        ;;
    deleted)
        emit '{"id":"resp_1","object":"response","deleted":true}'
        printf '200'
        ;;
    conversation)
        emit '{"id":"conv_1","object":"conversation","created_at":1,"metadata":{}}'
        printf '200'
        ;;
    compacted)
        emit '{"id":"resp_c","object":"response.compaction","output":[{"id":"cmp_1","type":"compaction","encrypted_content":"opaque"}]}'
        printf '200'
        ;;
    pages)
        if [[ "$n" -eq 1 ]]; then
            emit '{"object":"list","data":[{"id":"itm_1"},{"id":"itm_2"}],"first_id":"itm_1","last_id":"itm_2","has_more":true}'
        else
            emit '{"object":"list","data":[{"id":"itm_3"}],"first_id":"itm_3","last_id":"itm_3","has_more":false}'
        fi
        printf '200'
        ;;
    not-found)
        emit '{"error":{"message":"No such response: resp_missing","type":"invalid_request_error"}}'
        printf '404'
        ;;
    stream-terminal)
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","sequence_number":43,"delta":"hi"}'
        printf '%s\n\n' 'event: response.completed' 'data: {"type":"response.completed","sequence_number":44,"response":{"id":"resp_1","status":"completed"}}'
        ;;
    stream-truncated)
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","sequence_number":43,"delta":"hi"}'
        ;;
    *)
        echo "curl stub: unknown CURL_MODE=$CURL_MODE" >&2
        exit 2
        ;;
esac
STUB
chmod +x "$WORK/bin/curl"

export PATH="$WORK/bin:$PATH"
export HEADLONG_HOME="$WORK/home"
export OPENAI_API_KEY="test-openai-key"
export OPENROUTER_API_KEY="test-openrouter-key"
export CURL_ARGS="$WORK/curl.args"
export CURL_PAYLOAD="$WORK/curl.payload"
export CURL_CALLS="$WORK/curl.calls"
export CURL_LOG="$WORK/curl.log"
export CURL_AUTH="$WORK/curl.auth"
unset LLM_PROVIDER LLM_API_URL LLM_API_KEY SHELLM_API_URL
R="$REPO/bin/responses"

reset() {
    : > "$CURL_ARGS"; : > "$CURL_PAYLOAD"; : > "$CURL_LOG"; : > "$CURL_AUTH"
    rm -f "$CURL_CALLS" "$WORK/stdout" "$WORK/stderr"
}
run() { "$R" "$@" >"$WORK/stdout" 2>"$WORK/stderr"; }
logged() { cat "$CURL_LOG"; }

# --- get: path, verb, stdout contract ---------------------------------------
reset
export CURL_MODE=response
run get resp_1
rc=$?
if [[ "$rc" -eq 0 && "$(logged)" == "GET https://api.openai.com/v1/responses/resp_1" ]]; then
    ok "get retrieves GET /responses/{id} on the native OpenAI base"
else
    bad "get retrieves GET /responses/{id} on the native OpenAI base" "rc=$rc log=$(logged)"
fi
if [[ "$(wc -l < "$WORK/stdout" | tr -d ' ')" == "1" ]] \
   && jq -e '.id == "resp_1"' "$WORK/stdout" >/dev/null; then
    ok "stdout is the API object as one compact JSON line"
else
    bad "stdout is the API object as one compact JSON line" "$(cat "$WORK/stdout")"
fi

# The key reaches curl exactly the way bin/llm sends it: a 0600 config file
# holding one header line, never argv.
if ! grep -q 'test-openai-key' "$CURL_ARGS" \
   && [[ "$(cat "$CURL_AUTH")" == 'header = "Authorization: Bearer test-openai-key"' ]]; then
    ok "the key travels in a curl config header, never on argv"
else
    bad "the key travels in a curl config header, never on argv" "auth=$(cat "$CURL_AUTH")"
fi

# --- get: repeated include, net guards, pretty ------------------------------
reset
run get resp_1 --include reasoning.encrypted_content --include message.output_text.logprobs
url=$(sed -n '1s/^GET //p' "$CURL_LOG")
if [[ "$url" == "https://api.openai.com/v1/responses/resp_1?include[]=reasoning.encrypted_content&include[]=message.output_text.logprobs" ]]; then
    ok "repeated --include becomes repeated include[] query params in order"
else
    bad "repeated --include becomes repeated include[] query params in order" "url=$url"
fi

reset
LLM_CONNECT_TIMEOUT=3 LLM_MAX_TIME=44 run get resp_1
if grep -qx -- '--connect-timeout' "$CURL_ARGS" && grep -qx '3' "$CURL_ARGS" \
   && grep -qx -- '--max-time' "$CURL_ARGS" && grep -qx '44' "$CURL_ARGS"; then
    ok "LLM_CONNECT_TIMEOUT and LLM_MAX_TIME reach curl"
else
    bad "LLM_CONNECT_TIMEOUT and LLM_MAX_TIME reach curl"
fi

reset
run get resp_1 --pretty
[[ "$(wc -l < "$WORK/stdout" | tr -d ' ')" -gt 1 ]] \
    && ok "--pretty prints the object across lines" \
    || bad "--pretty prints the object across lines"

# --- cancel and delete ------------------------------------------------------
reset
run cancel resp_1
[[ "$(logged)" == "POST https://api.openai.com/v1/responses/resp_1/cancel" ]] \
    && ok "cancel posts to /responses/{id}/cancel" \
    || bad "cancel posts to /responses/{id}/cancel" "$(logged)"

reset
export CURL_MODE=deleted
run delete resp_1
if [[ "$(logged)" == "DELETE https://api.openai.com/v1/responses/resp_1" ]] \
   && jq -e '.deleted == true' "$WORK/stdout" >/dev/null; then
    ok "delete sends DELETE /responses/{id} and prints the deletion object"
else
    bad "delete sends DELETE /responses/{id} and prints the deletion object" "$(logged)"
fi

# --- input-items: query params and --all pagination -------------------------
reset
export CURL_MODE=pages
run input-items resp_1 --after itm_0 --limit 2 --order asc
url=$(sed -n '1s/^GET //p' "$CURL_LOG")
if [[ "$url" == "https://api.openai.com/v1/responses/resp_1/input_items?after=itm_0&limit=2&order=asc" ]]; then
    ok "input-items sends after, limit, and order"
else
    bad "input-items sends after, limit, and order" "url=$url"
fi
jq -e '.has_more == true' "$WORK/stdout" >/dev/null \
    && ok "a single page is printed as the API returned it" \
    || bad "a single page is printed as the API returned it" "$(cat "$WORK/stdout")"

reset
run input-items resp_1 --all
if [[ "$(cat "$CURL_CALLS")" == "2" ]] \
   && [[ "$(sed -n '2s/^GET //p' "$CURL_LOG")" == "https://api.openai.com/v1/responses/resp_1/input_items?after=itm_2" ]]; then
    ok "--all follows has_more with after=<last id of the page>"
else
    bad "--all follows has_more with after=<last id of the page>" "calls=$(cat "$CURL_CALLS") log=$(logged)"
fi
if jq -e '[.data[].id] == ["itm_1","itm_2","itm_3"] and .has_more == false
          and .first_id == "itm_1" and .last_id == "itm_3" and .object == "list"' \
        "$WORK/stdout" >/dev/null; then
    ok "--all prints one merged list object"
else
    bad "--all prints one merged list object" "$(cat "$WORK/stdout")"
fi

# --- error contract ---------------------------------------------------------
reset
export CURL_MODE=not-found
run get resp_missing
rc=$?
if [[ "$rc" -eq 1 && ! -s "$WORK/stdout" ]] \
   && grep -q '^responses: error: No such response: resp_missing$' "$WORK/stderr"; then
    ok "a non-2xx prints the API message on stderr, nothing on stdout, exit 1"
else
    bad "a non-2xx prints the API message on stderr, nothing on stdout, exit 1" \
        "rc=$rc out=$(cat "$WORK/stdout") err=$(cat "$WORK/stderr")"
fi

# --- usage errors: exit 2, before any request -------------------------------
export CURL_MODE=response
usage_case() {  # usage_case <label> <args...>
    local label="$1"; shift
    reset
    run "$@"
    local rc=$?
    if [[ "$rc" -eq 2 && ! -e "$CURL_CALLS" && ! -s "$WORK/stdout" ]]; then
        ok "usage error: $label"
    else
        bad "usage error: $label" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) err=$(cat "$WORK/stderr")"
    fi
}
usage_case "no subcommand"
usage_case "unknown subcommand" frobnicate
usage_case "get without an id" get
usage_case "get with a second positional" get resp_1 resp_2
usage_case "unknown option" get resp_1 --nope
usage_case "an option the subcommand does not take" cancel resp_1 --limit 5
usage_case "conversations update without --metadata" conversations update conv_1
usage_case "an unsupported provider" --provider anthropic get resp_1

reset
run --help
[[ $? -eq 0 && ! -e "$CURL_CALLS" ]] && grep -q 'responses get ID' "$WORK/stdout" \
    && ok "--help prints usage and exits 0" \
    || bad "--help prints usage and exits 0" "$(head -3 "$WORK/stdout")"

# conversations add refuses more than the API's 20 items before sending.
reset
jq -nc '[range(21) | {type:"message", role:"user", content:"x"}]' > "$WORK/items21.json"
run conversations add conv_1 --items-file "$WORK/items21.json"
rc=$?
if [[ "$rc" -eq 2 && ! -e "$CURL_CALLS" ]] && grep -q '20' "$WORK/stderr"; then
    ok "conversations add refuses more than 20 items before sending"
else
    bad "conversations add refuses more than 20 items before sending" "rc=$rc err=$(cat "$WORK/stderr")"
fi

# --- streaming get ----------------------------------------------------------
reset
export CURL_MODE=stream-terminal
run get resp_1 --stream --starting-after 42
rc=$?
url=$(sed -n '1s/^GET //p' "$CURL_LOG")
if [[ "$rc" -eq 0 && "$url" == "https://api.openai.com/v1/responses/resp_1?stream=true&starting_after=42" ]]; then
    ok "get --stream asks for stream=true with starting_after"
else
    bad "get --stream asks for stream=true with starting_after" "rc=$rc url=$url"
fi
if [[ "$(wc -l < "$WORK/stdout" | tr -d ' ')" == "2" ]] \
   && [[ "$(sed -n '2p' "$WORK/stdout" | jq -r '.type')" == "response.completed" ]]; then
    ok "each SSE data payload is printed as one JSON line"
else
    bad "each SSE data payload is printed as one JSON line" "$(cat "$WORK/stdout")"
fi

reset
export CURL_MODE=stream-truncated
run get resp_1 --stream
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q '^responses: error: ' "$WORK/stderr"; then
    ok "a stream that ends without a terminal event fails"
else
    bad "a stream that ends without a terminal event fails" "rc=$rc err=$(cat "$WORK/stderr")"
fi

# --- base URL derivation ----------------------------------------------------
reset
export CURL_MODE=response
LLM_PROVIDER=openai-compatible LLM_API_URL="https://router.test/v1/responses" \
    LLM_API_KEY=compat-key run get resp_1
if [[ "$(logged)" == "GET https://router.test/v1/responses/resp_1" ]] \
   && [[ "$(cat "$CURL_AUTH")" == 'header = "Authorization: Bearer compat-key"' ]]; then
    ok "LLM_API_URL loses its /responses suffix and becomes the base"
else
    bad "LLM_API_URL loses its /responses suffix and becomes the base" "$(logged) auth=$(cat "$CURL_AUTH")"
fi

reset
LLM_PROVIDER=openai-compatible LLM_API_URL="https://router.test/v1/chat/completions" \
    run get resp_1
[[ "$(logged)" == "GET https://router.test/v1/responses/resp_1" ]] \
    && ok "a /chat/completions URL yields the same base" \
    || bad "a /chat/completions URL yields the same base" "$(logged)"

reset
LLM_PROVIDER=openai-compatible run get resp_1
rc=$?
if [[ "$rc" -eq 1 && ! -e "$CURL_CALLS" ]] && grep -q 'LLM_API_URL' "$WORK/stderr"; then
    ok "openai-compatible without a URL fails before any request"
else
    bad "openai-compatible without a URL fails before any request" "rc=$rc err=$(cat "$WORK/stderr")"
fi

reset
run --provider openrouter get resp_1
[[ "$(logged)" == "GET https://openrouter.ai/api/v1/responses/resp_1" ]] \
    && ok "--provider openrouter uses the OpenRouter base" \
    || bad "--provider openrouter uses the OpenRouter base" "$(logged)"
[[ "$(cat "$CURL_AUTH")" == 'header = "Authorization: Bearer test-openrouter-key"' ]] \
    && ok "OpenRouter sends its own key" \
    || bad "OpenRouter sends its own key" "$(cat "$CURL_AUTH")"

# --- compact ----------------------------------------------------------------
reset
export CURL_MODE=compacted
printf '%s' '[{"role":"user","content":"hello"}]' > "$WORK/input.json"
printf '%s' '{"model":"wrong","instructions":"wrong","prompt_cache_key":"pck"}' > "$WORK/cbody.json"
run compact --model gpt-5.4-mini --input-file "$WORK/input.json" \
    --instructions "keep the plan" --body-file "$WORK/cbody.json"
if [[ "$(logged)" == "POST https://api.openai.com/v1/responses/compact" ]]; then
    ok "compact posts to /responses/compact"
else
    bad "compact posts to /responses/compact" "$(logged)"
fi
if jq -e '.model == "gpt-5.4-mini" and .instructions == "keep the plan"
          and .input == [{"role":"user","content":"hello"}]
          and .prompt_cache_key == "pck" and (has("previous_response_id") | not)' \
        "$CURL_PAYLOAD" >/dev/null; then
    ok "compact merges --body-file first and lets CLI-owned fields win"
else
    bad "compact merges --body-file first and lets CLI-owned fields win" "$(cat "$CURL_PAYLOAD")"
fi

reset
run compact --model gpt-5.4-mini --previous-response-id resp_1
jq -e '.previous_response_id == "resp_1" and (has("input") | not)' "$CURL_PAYLOAD" >/dev/null \
    && ok "compact sends previous_response_id when there is no input file" \
    || bad "compact sends previous_response_id when there is no input file" "$(cat "$CURL_PAYLOAD")"

usage_case "compact without an input source" compact --model gpt-5.4-mini
usage_case "compact with both input sources" compact --model m \
    --input-file "$WORK/input.json" --previous-response-id resp_1
usage_case "compact without a model" compact --input-file "$WORK/input.json"

# --- conversations ----------------------------------------------------------
reset
export CURL_MODE=conversation
printf '%s' '[{"type":"message","role":"user","content":"hi"}]' > "$WORK/items.json"
run conversations create --items-file "$WORK/items.json" --metadata '{"run":"r1"}'
if [[ "$(logged)" == "POST https://api.openai.com/v1/conversations" ]] \
   && jq -e '.items == [{"type":"message","role":"user","content":"hi"}] and .metadata.run == "r1"' \
        "$CURL_PAYLOAD" >/dev/null; then
    ok "conversations create posts items and metadata to /conversations"
else
    bad "conversations create posts items and metadata to /conversations" "$(logged) $(cat "$CURL_PAYLOAD")"
fi

reset
run conversations get conv_1
[[ "$(logged)" == "GET https://api.openai.com/v1/conversations/conv_1" ]] \
    && ok "conversations get reads /conversations/{cid}" \
    || bad "conversations get reads /conversations/{cid}" "$(logged)"

reset
run conversations update conv_1 --metadata '{"run":"r2"}'
if [[ "$(logged)" == "POST https://api.openai.com/v1/conversations/conv_1" ]] \
   && jq -e '. == {"metadata":{"run":"r2"}}' "$CURL_PAYLOAD" >/dev/null; then
    ok "conversations update posts metadata alone"
else
    bad "conversations update posts metadata alone" "$(logged) $(cat "$CURL_PAYLOAD")"
fi

reset
run conversations delete conv_1
[[ "$(logged)" == "DELETE https://api.openai.com/v1/conversations/conv_1" ]] \
    && ok "conversations delete removes the conversation" \
    || bad "conversations delete removes the conversation" "$(logged)"

reset
export CURL_MODE=pages
run conversations items conv_1 --limit 2 --order asc
url=$(sed -n '1s/^GET //p' "$CURL_LOG")
[[ "$url" == "https://api.openai.com/v1/conversations/conv_1/items?limit=2&order=asc" ]] \
    && ok "conversations items lists /conversations/{cid}/items" \
    || bad "conversations items lists /conversations/{cid}/items" "url=$url"

reset
run conversations items conv_1 --all
[[ "$(cat "$CURL_CALLS")" == "2" ]] \
    && jq -e '[.data[].id] == ["itm_1","itm_2","itm_3"]' "$WORK/stdout" >/dev/null \
    && ok "conversations items --all merges pages too" \
    || bad "conversations items --all merges pages too" "calls=$(cat "$CURL_CALLS")"

reset
export CURL_MODE=conversation
run conversations add conv_1 --items-file "$WORK/items.json" --include reasoning.encrypted_content
url=$(sed -n '1s/^POST //p' "$CURL_LOG")
if [[ "$url" == "https://api.openai.com/v1/conversations/conv_1/items?include[]=reasoning.encrypted_content" ]] \
   && jq -e '. == {"items":[{"type":"message","role":"user","content":"hi"}]}' "$CURL_PAYLOAD" >/dev/null; then
    ok "conversations add posts {items} with include on the query"
else
    bad "conversations add posts {items} with include on the query" "url=$url body=$(cat "$CURL_PAYLOAD")"
fi

reset
run conversations item conv_1 itm_1
[[ "$(logged)" == "GET https://api.openai.com/v1/conversations/conv_1/items/itm_1" ]] \
    && ok "conversations item reads one item" \
    || bad "conversations item reads one item" "$(logged)"

reset
run conversations remove conv_1 itm_1
[[ "$(logged)" == "DELETE https://api.openai.com/v1/conversations/conv_1/items/itm_1" ]] \
    && ok "conversations remove deletes one item" \
    || bad "conversations remove deletes one item" "$(logged)"

usage_case "conversations without a subcommand" conversations
usage_case "conversations add without --items-file" conversations add conv_1
usage_case "conversations item without an item id" conversations item conv_1
usage_case "metadata that is not a JSON object" conversations update conv_1 --metadata '[1]'
printf '%s' '{"not":"an array"}' > "$WORK/notarray.json"
usage_case "an items file that is not a JSON array" conversations add conv_1 \
    --items-file "$WORK/notarray.json"
usage_case "an items file that does not exist" conversations add conv_1 \
    --items-file "$WORK/missing.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
