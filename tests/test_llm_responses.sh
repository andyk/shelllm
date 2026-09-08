#!/usr/bin/env bash
# test_llm_responses.sh — OpenAI Responses completion protocol in bin/llm

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
printf '%s\n' "$((n + 1))" > "$CURL_CALLS"
printf '%s\n' "$@" > "$CURL_ARGS"
out_file=""
payload_file=""
prev=""
for arg in "$@"; do
    [[ "$prev" == "-o" ]] && out_file="$arg"
    [[ "$prev" == "-d" && "$arg" == @* ]] && payload_file="${arg#@}"
    prev="$arg"
done
[[ -n "$payload_file" ]] && cp "$payload_file" "$CURL_PAYLOAD"

buffered_completed='{
  "id":"resp_buffered",
  "object":"response",
  "status":"completed",
  "output":[
    {"id":"rs_1","type":"reasoning","summary":[{"type":"summary_text","text":"brief reasoning"}]},
    {"id":"msg_1","type":"message","role":"assistant","status":"completed","phase":"final_answer","content":[{"type":"output_text","text":"hello"}]}
  ],
  "usage":{"input_tokens":21,"output_tokens":8,"output_tokens_details":{"reasoning_tokens":3}}
}'

case "$CURL_MODE" in
    buffered-completed)
        printf '%s' "$buffered_completed" > "$out_file"
        printf '200'
        ;;
    buffered-multipart)
        printf '%s' '{"id":"resp_parts","object":"response","status":"completed","output":[{"id":"msg_parts","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"alpha"},{"type":"output_text","text":"\nbeta"},{"type":"refusal","refusal":"denied"}]}]}' > "$out_file"
        printf '200'
        ;;
    buffered-function)
        printf '%s' '{"id":"resp_fn","object":"response","status":"completed","output":[{"id":"fc_1","type":"function_call","call_id":"call_1","name":"weather","arguments":"{\"city\":\"Paris\"}","status":"completed"}],"usage":{"input_tokens":9,"output_tokens":4}}' > "$out_file"
        printf '200'
        ;;
    buffered-incomplete)
        printf '%s' '{"id":"resp_short","object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"id":"msg_2","type":"message","role":"assistant","status":"incomplete","content":[{"type":"output_text","text":"partial"}]}],"usage":{"input_tokens":7,"output_tokens":5}}' > "$out_file"
        printf '200'
        ;;
    buffered-failed)
        printf '%s' '{"id":"resp_failed","object":"response","status":"failed","error":{"code":"server_error","message":"generation failed"},"output":[]}' > "$out_file"
        printf '200'
        ;;
    http-400-previous)
        printf '%s' '{"error":{"message":"Previous response cannot be used for this organization due to Zero Data Retention.","type":"invalid_request_error","param":"previous_response_id","code":"unsupported_parameter"}}' > "$out_file"
        printf '400'
        ;;
    stream-completed)
        printf '%s\n\n' 'event: response.created' 'data: {"type":"response.created","response":{"id":"resp_stream","status":"in_progress","output":[]}}'
        printf '%s\n\n' 'event: response.reasoning_summary_text.delta' 'data: {"type":"response.reasoning_summary_text.delta","delta":"stream reasoning"}'
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","delta":"line one\n"}'
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","delta":"line two"}'
        printf '%s\n\n' 'event: response.completed' 'data: {"type":"response.completed","response":{"id":"resp_stream","object":"response","status":"completed","output":[{"id":"rs_s","type":"reasoning","summary":[{"type":"summary_text","text":"stream reasoning"}]},{"id":"msg_s","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"line one\nline two"}]}],"usage":{"input_tokens":30,"output_tokens":12,"output_tokens_details":{"reasoning_tokens":4}}}}'
        ;;
    stream-function)
        printf '%s\n\n' 'event: response.output_item.done' 'data: {"type":"response.output_item.done","item":{"id":"fc_s","type":"function_call","call_id":"call_s","name":"weather","arguments":"{}","status":"completed"}}'
        printf '%s\n\n' 'event: response.completed' 'data: {"type":"response.completed","response":{"id":"resp_stream_fn","object":"response","status":"completed","output":[{"id":"fc_s","type":"function_call","call_id":"call_s","name":"weather","arguments":"{}","status":"completed"}],"usage":{"input_tokens":5,"output_tokens":2}}}'
        ;;
    stream-failed)
        printf '%s\n\n' 'event: response.failed' 'data: {"type":"response.failed","response":{"id":"resp_stream_bad","object":"response","status":"failed","error":{"code":"server_error","message":"stream generation failed"},"output":[]}}'
        ;;
    stream-http-error)
        printf '%s\n' '{"error":{"message":"previous response missing","param":"previous_response_id","code":"previous_response_not_found"}}'
        ;;
    stream-flat-error)
        printf '%s\n\n' 'event: error' 'data: {"type":"error","message":"previous response missing","param":"previous_response_id","code":"previous_response_not_found"}'
        ;;
    stream-stop-after)
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","delta":"```bash\necho first\n```\n"}'
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","delta":"trailing prose\n```bash\necho second\n```\n"}'
        printf '%s\n\n' 'event: response.completed' 'data: {"type":"response.completed","response":{"id":"resp_cut","object":"response","status":"completed","output":[{"id":"msg_cut","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"```bash\necho first\n```\ntrailing prose\n```bash\necho second\n```\n"}]}],"usage":{"input_tokens":3,"output_tokens":9}}}'
        ;;
    stream-no-terminal)
        printf '%s\n\n' 'event: response.output_text.delta' 'data: {"type":"response.output_text.delta","delta":"```bash\nprintf pwned\n```"}'
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
export LLM_RETRIES=0
export CURL_ARGS="$WORK/curl.args"
export CURL_PAYLOAD="$WORK/curl.payload"
export CURL_CALLS="$WORK/curl.calls"
LLM="$REPO/bin/llm"

reset() {
    : > "$CURL_ARGS"
    : > "$CURL_PAYLOAD"
    rm -f "$CURL_CALLS" "$WORK/response.json" "$WORK/usage.json" "$WORK/stdout" "$WORK/stderr"
}

run_openai() {
    LLM_API_FORMAT=responses \
    LLM_RESPONSE_FILE="$WORK/response.json" \
    LLM_USAGE_FILE="$WORK/usage.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "$@"
}

# Buffered output, endpoint, sidecar, reasoning, and usage.
reset
export CURL_MODE=buffered-completed
run_openai --no-stream --thinking medium "say hello" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
[[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "hello" ]] \
    && ok "buffered Responses emits visible text" \
    || bad "buffered Responses emits visible text" "rc=$rc out=$(cat "$WORK/stdout")"
grep -q 'brief reasoning' "$WORK/stderr" \
    && ok "buffered Responses emits reasoning summary on stderr" \
    || bad "buffered Responses emits reasoning summary on stderr"
grep -q 'https://api.openai.com/v1/responses' "$CURL_ARGS" \
    && ok "native OpenAI selects /v1/responses" \
    || bad "native OpenAI selects /v1/responses"
jq -e '.id == "resp_buffered" and .output[1].phase == "final_answer"' "$WORK/response.json" >/dev/null \
    && ok "terminal Response sidecar preserves the full object" \
    || bad "terminal Response sidecar preserves the full object"
mode=$(stat -c %a "$WORK/response.json" 2>/dev/null || stat -f %Lp "$WORK/response.json")
[[ "$mode" == 600 ]] && ok "Response sidecar is mode 600" || bad "Response sidecar is mode 600" "mode=$mode"
jq -e '.in_tok == 21 and .out_tok == 8 and .think_tok == 3' "$WORK/usage.json" >/dev/null \
    && ok "Responses usage maps to the existing usage contract" \
    || bad "Responses usage maps to the existing usage contract" "$(cat "$WORK/usage.json")"
jq -e '(.include | index("reasoning.encrypted_content")) != null' "$CURL_PAYLOAD" >/dev/null \
    && ok "Responses requests include encrypted reasoning for stateless replay" \
    || bad "Responses requests include encrypted reasoning for stateless replay" "$(jq -c . "$CURL_PAYLOAD" 2>/dev/null)"

# Buffered content parts concatenate byte-for-byte like SSE deltas; jq's
# default record newlines must not alter the model's text.
reset
export CURL_MODE=buffered-multipart
run_openai --no-stream "multiple parts" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == $'alpha\nbetadenied' ]]; then
    ok "buffered Responses concatenates content parts without invented newlines"
else
    bad "buffered Responses concatenates content parts without invented newlines" "rc=$rc out=$(printf %q "$(cat "$WORK/stdout")")"
fi

# Structured input is not flattened, extra fields pass through, and owned
# fields win over conflicting values from the extra-body file.
reset
cat > "$WORK/body.json" <<'JSON'
{
  "model": "wrong-model",
  "input": "wrong-input",
  "stream": true,
  "max_output_tokens": 1,
  "instructions": "wrong instructions",
  "previous_response_id": "wrong-id",
  "store": false,
  "include": ["reasoning.encrypted_content"],
  "tools": [{"type":"function","name":"weather","description":"Weather","parameters":{"type":"object"},"strict":true}],
  "text": {"format":{"type":"json_schema","name":"answer","schema":{"type":"object"},"strict":true}}
}
JSON
cat > "$WORK/input.json" <<'JSON'
[
  {"role":"user","content":[{"type":"input_text","text":"describe"},{"type":"input_image","image_url":"data:image/png;base64,AAAA","detail":"low"}]},
  {"type":"reasoning","id":"rs_old","summary":[],"encrypted_content":"encrypted"},
  {"type":"function_call_output","call_id":"call_old","output":"sunny"}
]
JSON
export CURL_MODE=buffered-completed
LLM_API_FORMAT=responses \
LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
LLM_PREVIOUS_RESPONSE_ID="resp_previous" \
LLM_RESPONSE_FILE="$WORK/response.json" \
LLM_PROVIDER=openai-compatible \
LLM_API_URL="https://api.router.test/v1/responses" \
LLM_API_KEY="test-compatible-key" \
    "$LLM" -m glm-test --no-stream --thinking high --system-prompt "real instructions" \
    --messages-file "$WORK/input.json" >/dev/null 2>"$WORK/stderr"
if jq -e '
    .model == "glm-test" and
    .input[0].content[1].type == "input_image" and
    .input[1].encrypted_content == "encrypted" and
    .input[2].type == "function_call_output" and
    .stream == false and
    .max_output_tokens == 16384 and
    .instructions == "real instructions" and
    .previous_response_id == "resp_previous" and
    .store == false and
    (.include | index("reasoning.encrypted_content")) != null and
    .tools[0].name == "weather" and
    .text.format.type == "json_schema" and
    .reasoning.effort == "high" and
    .reasoning.summary == "auto"
' "$CURL_PAYLOAD" >/dev/null; then
    ok "Responses request preserves typed input and merges the create body"
else
    bad "Responses request preserves typed input and merges the create body" "$(jq -c . "$CURL_PAYLOAD" 2>/dev/null)"
fi
grep -q 'https://api.router.test/v1/responses' "$CURL_ARGS" \
    && ok "openai-compatible uses the exact configured Responses URL" \
    || bad "openai-compatible uses the exact configured Responses URL"

# Function-only responses are protocol success, not an empty-response error.
reset
export CURL_MODE=buffered-function
run_openai --no-stream "call the function" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && ! -s "$WORK/stdout" ]] \
   && jq -e '.output[0].type == "function_call" and .output[0].call_id == "call_1"' "$WORK/response.json" >/dev/null; then
    ok "buffered function-only Response succeeds through the sidecar"
else
    bad "buffered function-only Response succeeds through the sidecar" "rc=$rc out=$(cat "$WORK/stdout")"
fi

# Incomplete responses keep their partial output and warn.
reset
export CURL_MODE=buffered-incomplete
run_openai --no-stream "be long" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "partial" ]] && grep -q 'output truncated' "$WORK/stderr"; then
    ok "incomplete max-output Response returns partial text with warning"
else
    bad "incomplete max-output Response returns partial text with warning" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

# A 200 Response with status=failed is not successful output.
reset
export CURL_MODE=buffered-failed
LLM_RETRIES=2 run_openai --no-stream "fail" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'generation failed' "$WORK/stderr" \
   && jq -e '.status == "failed"' "$WORK/response.json" >/dev/null \
   && [[ "$(cat "$CURL_CALLS")" -eq 1 ]]; then
    ok "buffered failed Response fails once and preserves terminal state"
else
    bad "buffered failed Response fails once and preserves terminal state" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
fi

# Non-2xx error envelopes are available to machine callers for safe fallback.
reset
export CURL_MODE=http-400-previous
LLM_PREVIOUS_RESPONSE_ID=resp_stale run_openai --no-stream "continue" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] \
   && jq -e '.error.param == "previous_response_id" and .error.code == "unsupported_parameter"' "$WORK/response.json" >/dev/null; then
    ok "HTTP error envelope is written to the Response sidecar"
else
    bad "HTTP error envelope is written to the Response sidecar" "rc=$rc response=$(cat "$WORK/response.json" 2>/dev/null)"
fi

# SSE text/reasoning/terminal state and usage.
reset
export CURL_MODE=stream-completed
run_openai --thinking medium "stream" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == $'line one\nline two' ]]; then
    ok "Responses SSE preserves text delta newlines"
else
    bad "Responses SSE preserves text delta newlines" "rc=$rc out=$(printf %q "$(cat "$WORK/stdout")")"
fi
grep -q 'stream reasoning' "$WORK/stderr" \
    && ok "Responses SSE emits reasoning summary deltas on stderr" \
    || bad "Responses SSE emits reasoning summary deltas on stderr"
if jq -e '.id == "resp_stream" and .status == "completed"' "$WORK/response.json" >/dev/null \
   && jq -e '.in_tok == 30 and .out_tok == 12 and .think_tok == 4' "$WORK/usage.json" >/dev/null; then
    ok "Responses SSE records terminal Response and usage"
else
    bad "Responses SSE records terminal Response and usage"
fi

# Function-only streams count the terminal item as protocol output.
reset
export CURL_MODE=stream-function
run_openai "stream a function" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && ! -s "$WORK/stdout" ]] \
   && jq -e '.output[0].type == "function_call"' "$WORK/response.json" >/dev/null; then
    ok "function-only Responses SSE succeeds without visible stdout"
else
    bad "function-only Responses SSE succeeds without visible stdout" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

# Stream terminal failures and pre-SSE error bodies remain failures and leave
# structured state for the caller.
reset
export CURL_MODE=stream-failed
run_openai "stream failure" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'stream generation failed' "$WORK/stderr" \
   && jq -e '.status == "failed"' "$WORK/response.json" >/dev/null; then
    ok "terminal response.failed fails with structured state"
else
    bad "terminal response.failed fails with structured state" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

reset
export CURL_MODE=stream-http-error
LLM_RETRIES=2 LLM_PREVIOUS_RESPONSE_ID=resp_missing \
    run_openai "continue" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] \
   && jq -e '.error.param == "previous_response_id"' "$WORK/response.json" >/dev/null \
   && [[ "$(cat "$CURL_CALLS")" -eq 1 ]]; then
    ok "pre-SSE continuation rejection is preserved without internal retries"
else
    bad "pre-SSE continuation rejection is preserved without internal retries" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) response=$(cat "$WORK/response.json" 2>/dev/null)"
fi

reset
export CURL_MODE=stream-flat-error
LLM_RETRIES=2 LLM_PREVIOUS_RESPONSE_ID=resp_missing \
    run_openai "continue" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] \
   && jq -e '.param == "previous_response_id" and .code == "previous_response_not_found"' "$WORK/response.json" >/dev/null \
   && [[ "$(cat "$CURL_CALLS")" -eq 1 ]]; then
    ok "flat SSE continuation rejection is preserved without internal retries"
else
    bad "flat SSE continuation rejection is preserved without internal retries" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) response=$(cat "$WORK/response.json" 2>/dev/null)"
fi

# The same decision without a sidecar: the rejection is judged on the error
# body, so a caller that sets no LLM_RESPONSE_FILE does not pay for retries
# of a deterministic 400 either.
reset
export CURL_MODE=stream-http-error
LLM_API_FORMAT=responses LLM_RETRIES=2 LLM_PREVIOUS_RESPONSE_ID=resp_missing \
    "$LLM" --provider openai -m gpt-5.4-mini "continue" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 1 && "$(cat "$CURL_CALLS")" -eq 1 && ! -e "$WORK/response.json" ]] \
   && grep -q 'previous response missing' "$WORK/stderr"; then
    ok "continuation rejection is final without a Response sidecar"
else
    bad "continuation rejection is final without a Response sidecar" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
fi

# --stop-after-code-block keeps its contract in Responses mode: the stream is
# cut when the first block closes, the cut is a clean finish, and the missing
# terminal event means no sidecar and estimated usage.
reset
export CURL_MODE=stream-stop-after
run_openai --stop-after-code-block "cut" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == $'```bash\necho first\n```' && ! -e "$WORK/response.json" ]] \
   && grep -q 'stopped reading after the first code block' "$WORK/stderr" \
   && jq -e '.estimated == true' "$WORK/usage.json" >/dev/null; then
    ok "stop-after-code-block cuts a Responses stream cleanly"
else
    bad "stop-after-code-block cuts a Responses stream cleanly" "rc=$rc out=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr") usage=$(cat "$WORK/usage.json" 2>/dev/null)"
fi

reset
export CURL_MODE=stream-no-terminal
LLM_RETRIES=2 run_openai "truncated stream" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(cat "$CURL_CALLS")" -eq 1 ]] \
   && jq -e '.error.code == "outcome_unknown"' "$WORK/response.json" >/dev/null \
   && grep -q 'without a terminal response' "$WORK/stderr"; then
    ok "Responses SSE with output but no terminal event fails without retry"
else
    bad "Responses SSE with output but no terminal event fails without retry" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
fi

# Provider and body validation fail before curl.
reset
export CURL_MODE=buffered-completed
LLM_API_FORMAT=responses "$LLM" --provider anthropic -m claude-sonnet-4-5 "no" \
    >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'Responses format is not supported for provider anthropic' "$WORK/stderr"; then
    ok "unsupported provider fails explicitly"
else
    bad "unsupported provider fails explicitly" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

printf '[]' > "$WORK/body.json"
LLM_API_FORMAT=responses LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "no" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'must contain a JSON object' "$WORK/stderr"; then
    ok "Responses extra body must be an object"
else
    bad "Responses extra body must be an object" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

printf '{"background":true}' > "$WORK/body.json"
LLM_API_FORMAT=responses LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "no" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'background responses require lifecycle operations' "$WORK/stderr"; then
    ok "background Responses are rejected until lifecycle support exists"
else
    bad "background Responses are rejected until lifecycle support exists" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

printf '{"conversation":"conv_123"}' > "$WORK/body.json"
LLM_API_FORMAT=responses LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "no" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'conversation state cannot be combined' "$WORK/stderr"; then
    ok "conversation state is rejected before continuation can conflict"
else
    bad "conversation state is rejected before continuation can conflict" "rc=$rc stderr=$(cat "$WORK/stderr")"
fi

# OpenRouter has its own Responses endpoint but remains a separate stateless
# service from generic openai-compatible endpoints.
reset
export CURL_MODE=buffered-completed
LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$WORK/response.json" \
    "$LLM" --provider openrouter -m openai/gpt-5 --no-stream "hello" \
    >"$WORK/stdout" 2>"$WORK/stderr"
grep -q 'https://openrouter.ai/api/v1/responses' "$CURL_ARGS" \
    && ok "OpenRouter selects its documented Responses endpoint" \
    || bad "OpenRouter selects its documented Responses endpoint"
jq -e '(.include | index("reasoning.encrypted_content")) != null' "$CURL_PAYLOAD" >/dev/null \
    && ok "OpenRouter requests encrypted reasoning for exact replay" \
    || bad "OpenRouter requests encrypted reasoning for exact replay" "$(jq -c . "$CURL_PAYLOAD" 2>/dev/null)"


# A pinned route or a ZDR/no-training constraint says where the prompt may go,
# so it rides the Responses payload exactly as it rides chat, merged with any
# provider object the caller's body file already carries.
reset
export CURL_MODE=buffered-completed
printf '%s' '{"provider":{"sort":"price"}}' > "$WORK/or-body.json"
LLM_API_FORMAT=responses LLM_RESPONSES_BODY_FILE="$WORK/or-body.json" \
LLM_OR_ONLY=openai LLM_OR_DATA_COLLECTION=deny LLM_OR_ZDR=1 \
    "$LLM" --provider openrouter -m openai/gpt-5 --no-stream "route" \
    >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 ]] && jq -e '
    .provider == {sort:"price", only:["openai"], data_collection:"deny", zdr:true}
    and .model == "openai/gpt-5" and (.input | type == "array")
' "$CURL_PAYLOAD" >/dev/null; then
    ok "OpenRouter routing and privacy constraints ride the Responses payload"
else
    bad "OpenRouter routing and privacy constraints ride the Responses payload" "rc=$rc payload=$(jq -c . "$CURL_PAYLOAD" 2>/dev/null)"
fi
reset
export CURL_MODE=buffered-completed
LLM_API_FORMAT=responses \
    "$LLM" --provider openrouter -m openai/gpt-5 --no-stream "unpinned" \
    >"$WORK/stdout" 2>"$WORK/stderr"
jq -e 'has("provider") | not' "$CURL_PAYLOAD" >/dev/null \
    && ok "unpinned OpenRouter Responses payload carries no provider object" \
    || bad "unpinned OpenRouter Responses payload carries no provider object" "$(jq -c . "$CURL_PAYLOAD" 2>/dev/null)"

# A sidecar the caller asked for must be writable before any tokens are
# spent; a streaming reply cannot be failed cleanly for a missing directory.
reset
export CURL_MODE=stream-completed
LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$WORK/missing-dir/response.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "sidecar" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && ! -e "$CURL_CALLS" && ! -s "$WORK/stdout" ]] \
   && grep -q 'Response file directory does not exist' "$WORK/stderr"; then
    ok "an unwritable Response sidecar fails before any request"
else
    bad "an unwritable Response sidecar fails before any request" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
fi
# A path that names a directory would let mv "succeed" by dropping the temp
# file inside it, with nothing at the path the caller reads.
reset
mkdir -p "$WORK/as-dir"
LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$WORK/as-dir" \
    "$LLM" --provider openai -m gpt-5.4-mini "sidecar" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && ! -e "$CURL_CALLS" && -d "$WORK/as-dir" ]] \
   && grep -q 'Response file is a directory' "$WORK/stderr" \
   && [[ -z "$(ls -A "$WORK/as-dir")" ]]; then
    ok "a directory as Response sidecar fails before any request"
else
    bad "a directory as Response sidecar fails before any request" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
fi
reset
mkdir -p "$WORK/locked" && chmod 500 "$WORK/locked"
if [[ -w "$WORK/locked" ]]; then
    ok "a read-only sidecar directory fails before any request (skipped: directory writable, probably root)"
else
    LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$WORK/locked/response.json" \
        "$LLM" --provider openai -m gpt-5.4-mini "sidecar" >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && ! -e "$CURL_CALLS" ]] \
       && grep -q 'Response file directory is not writable' "$WORK/stderr"; then
        ok "a read-only sidecar directory fails before any request"
    else
        bad "a read-only sidecar directory fails before any request" "rc=$rc calls=$(cat "$CURL_CALLS" 2>/dev/null) stderr=$(cat "$WORK/stderr")"
    fi
fi
chmod 700 "$WORK/locked"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
