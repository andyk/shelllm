#!/usr/bin/env bash
# test_shellm_responses_continuation.sh — persisted Responses continuation and
# one-time full-context fallback in shellm.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0
messages_file=""
prev=""
for arg in "$@"; do
    [[ "$arg" == --thinking ]] && main_loop=1
    [[ "$prev" == --messages-file ]] && messages_file="$arg"
    prev="$arg"
done
if [[ "$main_loop" -ne 1 ]]; then
    printf '{}\n'
    exit 0
fi

n=0
[[ -f "$LLM_STUB_DIR/calls" ]] && read -r n < "$LLM_STUB_DIR/calls"
n=$((n + 1))
printf '%s\n' "$n" > "$LLM_STUB_DIR/calls"
printf '%s\n' "${LLM_API_FORMAT:-}" > "$LLM_STUB_DIR/format-$n"
printf '%s\n' "${LLM_PREVIOUS_RESPONSE_ID:-}" > "$LLM_STUB_DIR/previous-$n"
printf '%s\n' "${LLM_RESPONSES_BACKGROUND-unset}" > "$LLM_STUB_DIR/background-$n"
printf '%s\n' "${LLM_RESPONSES_COMPACT_THRESHOLD-unset}" > "$LLM_STUB_DIR/threshold-$n"
printf '%s\n' "${LLM_RESPONSE_FILE:-}" > "$LLM_STUB_DIR/response-file-$n"
[[ -n "$messages_file" ]] && cp "$messages_file" "$LLM_STUB_DIR/messages-$n.json"
if [[ -n "${LLM_RESPONSE_FILE:-}" ]]; then
    state_dir=$(dirname "$LLM_RESPONSE_FILE")
    if [[ -f "$state_dir/.response-id" ]]; then
        cp "$state_dir/.response-id" "$LLM_STUB_DIR/id-value-$n"
        (stat -c %a "$state_dir/.response-id" 2>/dev/null \
            || stat -f %Lp "$state_dir/.response-id" 2>/dev/null) \
            > "$LLM_STUB_DIR/id-mode-$n"
    fi
    [[ -e "$state_dir/.continuation-disabled" ]] \
        && printf 'yes\n' > "$LLM_STUB_DIR/disabled-$n" \
        || printf 'no\n' > "$LLM_STUB_DIR/disabled-$n"
fi

write_response() {
    local id="$1"
    [[ -n "${LLM_RESPONSE_FILE:-}" ]] || return 0
    ( umask 077; jq -nc --arg id "$id" '{
        id: $id,
        object: "response",
        status: "completed",
        output: [
            {id:("rs_" + $id), type:"reasoning", summary:[], encrypted_content:("enc_" + $id)},
            {id:("msg_" + $id), type:"message", role:"assistant", status:"completed", phase:"final_answer", content:[{type:"output_text", text:("text_" + $id)}]}
        ]
    }' > "$LLM_RESPONSE_FILE" )
}

# Same terminal object plus a usage block, so the caller can drive shellm's
# compaction threshold from the reported input tokens.
write_response_usage() {
    local id="$1" input_tokens="$2"
    [[ -n "${LLM_RESPONSE_FILE:-}" ]] || return 0
    ( umask 077; jq -nc --arg id "$id" --argjson in_tok "$input_tokens" '{
        id: $id,
        object: "response",
        status: "completed",
        output: [
            {id:("rs_" + $id), type:"reasoning", summary:[], encrypted_content:("enc_" + $id)},
            {id:("msg_" + $id), type:"message", role:"assistant", status:"completed", phase:"final_answer", content:[{type:"output_text", text:("text_" + $id)}]}
        ],
        usage: {input_tokens: $in_tok, output_tokens: 4}
    }' > "$LLM_RESPONSE_FILE" )
}

# A turn the server compacted for us: the terminal output carries a compaction
# item, and everything before it is no longer part of the next window.
write_response_server_compacted() {
    local id="$1"
    [[ -n "${LLM_RESPONSE_FILE:-}" ]] || return 0
    ( umask 077; jq -nc --arg id "$id" '{
        id: $id,
        object: "response",
        status: "completed",
        output: [
            {id:("rs_" + $id), type:"reasoning", summary:[], encrypted_content:("enc_" + $id)},
            {id:"cmp_server", type:"compaction", encrypted_content:"enc_server_compaction"},
            {id:("msg_" + $id), type:"message", role:"assistant", status:"completed", phase:"final_answer", content:[{type:"output_text", text:("text_" + $id)}]}
        ]
    }' > "$LLM_RESPONSE_FILE" )
}

case "$LLM_STUB_MODE:$n" in
    compact:1|compactfail:1|stateful-compact:1)
        write_response_usage resp_1 9000
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    compact:2|compactfail:2|stateful-compact:2)
        write_response_usage resp_2 10
        printf '%s\n' '```bash' 'FINAL=done-after-compaction' '```'
        ;;
    server-compaction:1)
        write_response_server_compacted resp_1
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    server-compaction:2)
        write_response resp_2
        printf '%s\n' '```bash' 'FINAL=done-after-server-compaction' '```'
        ;;
    continue:1|fallback:1|stateless:1)
        write_response resp_1
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    continue:2|stateless:2)
        write_response resp_2
        printf '%s\n' '```bash' 'FINAL=done' '```'
        ;;
    fallback:2)
        ( umask 077; printf '%s' '{"error":{"message":"previous response is unavailable","param":"previous_response_id","code":"previous_response_not_found"}}' > "$LLM_RESPONSE_FILE" )
        printf '%s\n' 'llm: error: API error (HTTP 400): previous response is unavailable' >&2
        exit 1
        ;;
    partial:1)
        write_response resp_1
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    partial:2)
        # Text was already streamed when the error arrived: not a rejection.
        printf '%s\n' '```bash' 'echo partial'
        ( umask 077; printf '%s' '{"error":{"message":"previous response is unavailable","param":"previous_response_id","code":"previous_response_not_found"}}' > "$LLM_RESPONSE_FILE" )
        printf '%s\n' 'llm: error: API stream error: previous response is unavailable' >&2
        exit 1
        ;;
    long:1)
        write_response resp_1
        printf '%s\n' '```bash' "printf '%03000d\\n' 1" '```'
        ;;
    long:2)
        write_response resp_2
        printf '%s\n' '```bash' 'echo second' '```'
        ;;
    long:3)
        write_response resp_3
        printf '%s\n' '```bash' 'FINAL=done-after-long' '```'
        ;;
    fallback:3)
        write_response resp_3
        printf '%s\n' '```bash' 'FINAL=done-after-fallback' '```'
        ;;
    empty:1)
        ( umask 077; jq -nc '{
            id: "resp_incomplete",
            object: "response",
            status: "incomplete",
            incomplete_details: {reason: "max_output_tokens"},
            output: [{id:"rs_incomplete", type:"reasoning", summary:[], encrypted_content:"enc_incomplete"}]
        }' > "$LLM_RESPONSE_FILE" )
        printf '%s\n' 'llm: warning: output truncated (max_output_tokens)' >&2
        ;;
    empty:2)
        write_response resp_after_incomplete
        printf '%s\n' '```bash' 'FINAL=done-after-incomplete' '```'
        ;;
    function:1)
        ( umask 077; jq -nc '{
            id: "resp_function",
            object: "response",
            status: "completed",
            output: [{id:"fc_1", type:"function_call", call_id:"call_1", name:"weather", arguments:"{}", status:"completed"}]
        }' > "$LLM_RESPONSE_FILE" )
        ;;
    no-terminal:1)
        printf '%s\n' '```bash' "touch '$LLM_STUB_DIR/executed'" '```'
        ;;
    chat:1)
        [[ -z "${LLM_RESPONSE_FILE:-}" ]] || { echo "chat unexpectedly received LLM_RESPONSE_FILE" >&2; exit 2; }
        printf '%s\n' '```bash' 'FINAL=chat-done' '```'
        ;;
    *)
        echo "unexpected stub call $LLM_STUB_MODE:$n" >&2
        exit 2
        ;;
esac
STUB
chmod +x "$WORK/toolbin/llm"

# The compaction endpoint, stubbed. It records the window it was handed and
# answers with the canonical next window: one compaction item, nothing else.
cat > "$WORK/toolbin/responses" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == compact ]] || { echo "unexpected responses command ${1:-}" >&2; exit 2; }
n=0
[[ -f "$LLM_STUB_DIR/compact-calls" ]] && read -r n < "$LLM_STUB_DIR/compact-calls"
n=$((n + 1))
printf '%s\n' "$n" > "$LLM_STUB_DIR/compact-calls"
model=""
input_file=""
prev=""
for arg in "$@"; do
    [[ "$prev" == --model ]] && model="$arg"
    [[ "$prev" == --input-file ]] && input_file="$arg"
    prev="$arg"
done
printf '%s\n' "$model" > "$LLM_STUB_DIR/compact-model-$n"
[[ -n "$input_file" ]] && cp "$input_file" "$LLM_STUB_DIR/compact-input-$n.json"
if [[ "$LLM_STUB_MODE" == compactfail ]]; then
    echo "responses: error: compaction is unavailable" >&2
    exit 1
fi
jq -nc '{
    id: "resp_compacted",
    object: "response",
    status: "completed",
    output: [{id: "cmp_1", type: "compaction", encrypted_content: "enc_compacted"}]
}'
STUB
chmod +x "$WORK/toolbin/responses"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export OPENAI_API_KEY="test-key"
export OPENROUTER_API_KEY="test-router-key"
export SHELLM_MODEL="gpt-5-test"
export SHELLM_ENV=local
export SHELLM_NO_BANNER=1

run_shellm() {
    local mode="$1" format="$2" provider="${3:-}" model="${4:-gpt-5-test}"
    rm -rf "$WORK/stub" "$HEADLONG_HOME" "$WORK/wd"/*
    mkdir -p "$WORK/stub" "$WORK/wd"
    LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE="$mode" SHELLM_API_FORMAT="$format" \
        LLM_PROVIDER="$provider" SHELLM_MODEL="$model" \
        "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 3 "do the task" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

main_calls() { cat "$WORK/stub/calls" 2>/dev/null || echo 0; }
compact_calls() { cat "$WORK/stub/compact-calls" 2>/dev/null || echo 0; }

# A successful terminal response becomes the next request's continuation ID;
# only the messages after the last assistant turn are sent as new input.
run_shellm continue responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(cat "$WORK/stub/previous-2")" == resp_1 ]]; then
    ok "later shellm iterations use the persisted previous_response_id"
else
    bad "later shellm iterations use the persisted previous_response_id" "rc=$rc calls=$(main_calls) previous=$(cat "$WORK/stub/previous-2" 2>/dev/null)"
fi

if [[ "$(cat "$WORK/stub/format-1")" == responses && -n "$(cat "$WORK/stub/response-file-1")" ]]; then
    ok "shellm opts llm into Responses and requests a terminal sidecar"
else
    bad "shellm opts llm into Responses and requests a terminal sidecar"
fi

if jq -e 'length == 1 and .[0].role == "user" and (. [0].content | contains("first output"))' \
        "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "continuation sends only input after the last assistant turn"
else
    bad "continuation sends only input after the last assistant turn" "$(jq -c . "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

if [[ "$(cat "$WORK/stub/id-value-2" 2>/dev/null)" == resp_1 \
    && "$(cat "$WORK/stub/id-mode-2" 2>/dev/null)" == 600 ]]; then
    ok "successful Response ID persists in mode-600 process state"
else
    bad "successful Response ID persists in mode-600 process state" "value=$(cat "$WORK/stub/id-value-2" 2>/dev/null) mode=$(cat "$WORK/stub/id-mode-2" 2>/dev/null)"
fi

# A provider rejection tied to previous_response_id clears continuation and
# retries once with the exact replay chain. It then stays disabled so the next
# iteration cannot enter a fallback loop.
run_shellm fallback responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 3 \
      && "$(cat "$WORK/stub/previous-2")" == resp_1 \
      && -z "$(cat "$WORK/stub/previous-3")" ]]; then
    ok "rejected continuation retries once without previous_response_id"
else
    bad "rejected continuation retries once without previous_response_id" "rc=$rc calls=$(main_calls) prev2=$(cat "$WORK/stub/previous-2" 2>/dev/null) prev3=$(cat "$WORK/stub/previous-3" 2>/dev/null)"
fi

if jq -e '
    length >= 4 and
    any(.role == "user" and (.content | contains("do the task"))) and
    any(.type == "reasoning" and .encrypted_content == "enc_resp_1") and
    any(.type == "message" and .role == "assistant" and .phase == "final_answer") and
    any(.role == "user" and (.content | contains("first output")))
' "$WORK/stub/messages-3.json" >/dev/null 2>&1; then
    ok "continuation fallback replays exact typed Responses items"
else
    bad "continuation fallback replays exact typed Responses items" "$(jq -c . "$WORK/stub/messages-3.json" 2>/dev/null)"
fi

if [[ ! -e "$WORK/stub/id-value-3" \
    && "$(cat "$WORK/stub/disabled-3" 2>/dev/null)" == yes ]] \
    && grep -q 'retrying once with exact replay context' "$WORK/err"; then
    ok "fallback clears persisted continuation state and disables reuse"
else
    bad "fallback clears persisted continuation state and disables reuse" "id=$(cat "$WORK/stub/id-value-3" 2>/dev/null) disabled=$(cat "$WORK/stub/disabled-3" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

# OpenRouter documents its Responses endpoint as stateless. It must replay
# exact output items from the first turn without first paying for a rejected
# previous_response_id request.
run_shellm stateless responses openrouter openai/o4-mini
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 \
    && -z "$(cat "$WORK/stub/previous-1")" \
    && -z "$(cat "$WORK/stub/previous-2")" ]]; then
    ok "OpenRouter Responses starts in stateless replay mode"
else
    bad "OpenRouter Responses starts in stateless replay mode" "rc=$rc calls=$(main_calls) prev1=$(cat "$WORK/stub/previous-1" 2>/dev/null) prev2=$(cat "$WORK/stub/previous-2" 2>/dev/null)"
fi

if jq -e '
    length >= 4 and
    any(.type == "reasoning" and .encrypted_content == "enc_resp_1") and
    any(.type == "message" and .phase == "final_answer") and
    any(.role == "user" and (.content | contains("first output")))
' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "OpenRouter replay preserves reasoning and assistant phase items"
else
    bad "OpenRouter replay preserves reasoning and assistant phase items" "$(jq -c . "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

# A reasoning-only incomplete Response continues from the terminal Response
# state. Its reasoning summary is never fabricated as an assistant message.
run_shellm empty responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 \
    && "$(cat "$WORK/stub/previous-2")" == resp_incomplete ]]; then
    ok "reasoning-only incomplete Response continues by response ID"
else
    bad "reasoning-only incomplete Response continues by response ID" "rc=$rc calls=$(main_calls) previous=$(cat "$WORK/stub/previous-2" 2>/dev/null)"
fi

if jq -e '
    length == 1 and
    .[0].role == "user" and
    (. [0].content | contains("Continue from the incomplete response")) and
    all(.[]; .role != "assistant")
' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "Responses retry does not fabricate assistant reasoning context"
else
    bad "Responses retry does not fabricate assistant reasoning context" "$(jq -c . "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

# shellm cannot execute Responses-native function calls. It fails closed
# instead of treating empty stdout as another model turn.
run_shellm function responses
rc=$?
if [[ "$rc" -ne 0 && "$(main_calls)" -eq 1 ]] \
    && grep -q 'function calls without visible shellm output' "$WORK/err"; then
    ok "function-only Response fails closed without an empty-output retry"
else
    bad "function-only Response fails closed without an empty-output retry" "rc=$rc calls=$(main_calls) stderr=$(tail -5 "$WORK/err" | tr '\n' ' ')"
fi

# Defense in depth: even a malformed/custom llm that exits successfully after
# visible output cannot make shellm execute without terminal Responses state.
run_shellm no-terminal responses
rc=$?
if [[ "$rc" -ne 0 && "$(main_calls)" -eq 1 && ! -e "$WORK/stub/executed" ]] \
    && grep -q 'without a terminal response' "$WORK/err"; then
    ok "shellm rejects Responses output without terminal state before execution"
else
    bad "shellm rejects Responses output without terminal state before execution" "rc=$rc calls=$(main_calls) stderr=$(tail -5 "$WORK/err" | tr '\n' ' ')"
fi

# The render shrinks an output once it ages out of the newest block, so the
# earlier context is not a byte prefix of the later one. New rows are told
# apart by id, and the run reaches its third call with only the new output.
run_shellm long responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 3 && "$(cat "$WORK/stub/previous-3")" == resp_2 ]] \
   && jq -e '
        length == 1 and .[0].role == "user"
        and (.[0].content | contains("second"))
        and (.[0].content | contains("000000") | not)
   ' "$WORK/stub/messages-3.json" >/dev/null 2>&1 \
   && jq -e 'any(.[]; .content | contains("000000"))' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "continuation survives an older output shrinking in the render"
else
    bad "continuation survives an older output shrinking in the render" "rc=$rc calls=$(main_calls) prev3=$(cat "$WORK/stub/previous-3" 2>/dev/null) m3=$(jq -c 'map(.content |= .[0:60])' "$WORK/stub/messages-3.json" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi
if ! grep -q 'step_ids' "$WORK/stub"/messages-*.json; then
    ok "row ids never reach the provider"
else
    bad "row ids never reach the provider" "$(grep -l 'step_ids' "$WORK/stub"/messages-*.json | tr '\n' ' ')"
fi

# A rejection can only precede generation. An error naming
# previous_response_id after text was streamed is a failed call, not a cue to
# replay, and the partial text is never executed.
run_shellm partial responses
rc=$?
if [[ "$rc" -ne 0 && "$(main_calls)" -eq 2 ]] \
   && ! grep -q 'retrying once with exact replay' "$WORK/err" \
   && grep -q 'llm failed' "$WORK/err"; then
    ok "continuation fallback requires a call that emitted nothing"
else
    bad "continuation fallback requires a call that emitted nothing" "rc=$rc calls=$(main_calls) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

# A bounded run context keeps working after its earlier rows scroll out of
# view: the pinned prompt is never resent against an existing continuation,
# and the run does not fail closed for it.
SHELLM_CONTEXT_SCOPE=run SHELLM_CONTEXT_RUN_TAIL=1 SHELLM_CONTEXT_RUN_TAIL_BLOCK=1 \
    run_shellm continue responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(cat "$WORK/stub/previous-2")" == resp_1 ]] \
   && jq -e '
        length >= 1
        and all(.[]; .role == "user" and (.content | contains("do the task") | not))
        and any(.[]; .content | contains("first output"))
   ' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "bounded run context sends only new rows, never the pinned prompt"
else
    bad "bounded run context sends only new rows, never the pinned prompt" "rc=$rc calls=$(main_calls) m2=$(jq -c 'map(.content |= .[0:60])' "$WORK/stub/messages-2.json" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

# Invalid protocol configuration fails through shellm's normal error contract,
# rather than calling the error helper before it has been defined.
SHELLM_API_FORMAT=invalid "$WORK/toolbin/shellm" --help \
    > "$WORK/out" 2> "$WORK/err"
rc=$?
if [[ "$rc" -ne 0 ]] \
    && grep -q 'Invalid SHELLM_API_FORMAT: invalid' "$WORK/err" \
    && ! grep -q 'command not found' "$WORK/err"; then
    ok "invalid Responses format fails through shellm's error contract"
else
    bad "invalid Responses format fails through shellm's error contract" "rc=$rc stderr=$(cat "$WORK/err")"
fi

# Background creates ride through to llm untouched; the continuation contract
# is llm's terminal object either way, so nothing else changes.
SHELLM_RESPONSES_BACKGROUND=1 run_shellm continue responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 \
      && "$(cat "$WORK/stub/background-1")" == 1 && "$(cat "$WORK/stub/background-2")" == 1 \
      && "$(cat "$WORK/stub/previous-2")" == resp_1 ]]; then
    ok "SHELLM_RESPONSES_BACKGROUND passes through to every llm call"
else
    bad "SHELLM_RESPONSES_BACKGROUND passes through to every llm call" "rc=$rc calls=$(main_calls) bg1=$(cat "$WORK/stub/background-1" 2>/dev/null) bg2=$(cat "$WORK/stub/background-2" 2>/dev/null)"
fi
run_shellm continue responses
if [[ "$(cat "$WORK/stub/background-1")" == unset ]]; then
    ok "an unset SHELLM_RESPONSES_BACKGROUND leaves llm's default alone"
else
    bad "an unset SHELLM_RESPONSES_BACKGROUND leaves llm's default alone" "bg1=$(cat "$WORK/stub/background-1" 2>/dev/null)"
fi
SHELLM_RESPONSES_BACKGROUND=sometimes "$WORK/toolbin/shellm" --help > "$WORK/out" 2> "$WORK/err"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'Invalid SHELLM_RESPONSES_BACKGROUND' "$WORK/err"; then
    ok "an invalid SHELLM_RESPONSES_BACKGROUND fails through shellm's error contract"
else
    bad "an invalid SHELLM_RESPONSES_BACKGROUND fails through shellm's error contract" "rc=$rc stderr=$(cat "$WORK/err")"
fi

# Default chat mode does not create or pass Responses state.
run_shellm chat chat
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stub/format-1")" == chat \
      && -z "$(cat "$WORK/stub/previous-1")" \
      && -z "$(rg --files "$HEADLONG_HOME/trajectories" 2>/dev/null | rg '/responses/' | head -1)" ]]; then
    ok "default chat mode remains stateless"
else
    bad "default chat mode remains stateless" "rc=$rc format=$(cat "$WORK/stub/format-1")"
fi

# Compaction in replay mode. Once a terminal response reports input tokens at
# or above the threshold, shellm compacts the chain itself and the next request
# opens with the window the compact endpoint returned, nothing before it.
SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 \
    run_shellm compact responses openrouter openai/o4-mini
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(compact_calls)" -eq 1 \
      && "$(cat "$WORK/stub/compact-model-1")" == openai/o4-mini ]]; then
    ok "a crossed compaction threshold compacts the replay chain once"
else
    bad "a crossed compaction threshold compacts the replay chain once" "rc=$rc calls=$(main_calls) compacts=$(compact_calls) model=$(cat "$WORK/stub/compact-model-1" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

if jq -e '
    .[0].type == "compaction" and .[0].encrypted_content == "enc_compacted" and
    all(.[]; .encrypted_content != "enc_resp_1") and
    any(.[]; .role == "user" and (.content | contains("first output")))
' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "the compacted window replaces the chain and opens the next request"
else
    bad "the compacted window replaces the chain and opens the next request" "$(jq -c 'map(if .content? then (.content |= (. | tostring)[0:40]) else . end)' "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

if jq -e '
    any(.[]; .encrypted_content == "enc_resp_1") and
    any(.[]; .role == "user" and (.content | contains("do the task")))
' "$WORK/stub/compact-input-1.json" >/dev/null 2>&1; then
    ok "the compact call is handed the whole replay chain"
else
    bad "the compact call is handed the whole replay chain" "$(jq -c 'map(.type // .role)' "$WORK/stub/compact-input-1.json" 2>/dev/null)"
fi

if grep -q 'compacting the Responses replay chain' "$WORK/err"; then
    ok "compaction logs one progress line"
else
    bad "compaction logs one progress line" "stderr=$(tail -5 "$WORK/err" | tr '\n' ' ')"
fi

# A compact call that fails is not fatal: the chain is kept exactly as it was
# and the run carries on.
SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 \
    run_shellm compactfail responses openrouter openai/o4-mini
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(compact_calls)" -eq 1 ]] \
   && jq -e 'any(.[]; .encrypted_content == "enc_resp_1")' "$WORK/stub/messages-2.json" >/dev/null 2>&1 \
   && grep -q 'compaction failed' "$WORK/err"; then
    ok "a failed compact call warns and keeps the replay chain"
else
    bad "a failed compact call warns and keeps the replay chain" "rc=$rc calls=$(main_calls) compacts=$(compact_calls) stderr=$(tail -5 "$WORK/err" | tr '\n' ' ')"
fi

# Stateful mode leaves compaction to the server: llm gets the threshold and
# shellm never calls the compact endpoint.
SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 run_shellm stateful-compact responses
rc=$?
if [[ "$rc" -eq 0 && "$(compact_calls)" -eq 0 \
      && "$(cat "$WORK/stub/threshold-1")" == 1000 \
      && "$(cat "$WORK/stub/threshold-2")" == 1000 ]]; then
    ok "stateful mode passes the threshold to llm and compacts nothing itself"
else
    bad "stateful mode passes the threshold to llm and compacts nothing itself" "rc=$rc compacts=$(compact_calls) t1=$(cat "$WORK/stub/threshold-1" 2>/dev/null) t2=$(cat "$WORK/stub/threshold-2" 2>/dev/null)"
fi

SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 \
    run_shellm compact responses openrouter openai/o4-mini
if [[ "$(cat "$WORK/stub/threshold-1")" == unset ]]; then
    ok "replay mode compacts locally and does not ask llm for server compaction"
else
    bad "replay mode compacts locally and does not ask llm for server compaction" "t1=$(cat "$WORK/stub/threshold-1" 2>/dev/null)"
fi

run_shellm continue responses
if [[ "$(cat "$WORK/stub/threshold-1")" == unset ]]; then
    ok "an unset compaction threshold reaches llm as unset"
else
    bad "an unset compaction threshold reaches llm as unset" "t1=$(cat "$WORK/stub/threshold-1" 2>/dev/null)"
fi

SHELLM_RESPONSES_COMPACT_THRESHOLD=lots "$WORK/toolbin/shellm" --help \
    > "$WORK/out" 2> "$WORK/err"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'Invalid SHELLM_RESPONSES_COMPACT_THRESHOLD' "$WORK/err"; then
    ok "an invalid compaction threshold fails through shellm's error contract"
else
    bad "an invalid compaction threshold fails through shellm's error contract" "rc=$rc stderr=$(cat "$WORK/err")"
fi

# Server-side compaction inside an ordinary turn: the terminal output carries a
# compaction item, so the chain is cut back to it with no threshold set and no
# compact call of our own.
run_shellm server-compaction responses openrouter openai/o4-mini
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(compact_calls)" -eq 0 ]] \
   && jq -e '
        .[0].type == "compaction" and .[0].encrypted_content == "enc_server_compaction" and
        all(.[]; .encrypted_content != "enc_resp_1")
   ' "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "a compaction item in a terminal output truncates the replay chain"
else
    bad "a compaction item in a terminal output truncates the replay chain" "rc=$rc calls=$(main_calls) compacts=$(compact_calls) m2=$(jq -c 'map(.type // .role)' "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
