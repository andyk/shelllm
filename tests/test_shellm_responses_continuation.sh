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
printf '%s\n' "${LLM_RESPONSES_CONVERSATION-unset}" > "$LLM_STUB_DIR/conversation-$n"
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

case "$LLM_STUB_MODE:$n" in
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

# bin/responses is the lifecycle tool shellm asks for a conversation. The stub
# records the create call and can refuse it, so the fail-closed path is
# exercised without a network.
cat > "$WORK/toolbin/responses" <<'STUB'
#!/usr/bin/env bash
mkdir -p "$RESPONSES_STUB_DIR"
n=0
[[ -f "$RESPONSES_STUB_DIR/creates" ]] && read -r n < "$RESPONSES_STUB_DIR/creates"
n=$((n + 1))
printf '%s\n' "$n" > "$RESPONSES_STUB_DIR/creates"
printf '%s\n' "$@" > "$RESPONSES_STUB_DIR/create-args-$n"
if [[ "${RESPONSES_STUB_MODE:-ok}" == reject ]]; then
    printf '%s\n' 'responses: error: Conversation not found' >&2
    exit 1
fi
printf '%s\n' '{"id":"conv_created","object":"conversation","created_at":1}'
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
create_calls() { cat "$WORK/rstub/creates" 2>/dev/null || echo 0; }
export RESPONSES_STUB_DIR="$WORK/rstub"

# Resume the run just made: same trajectory and the same create counter, so a
# reused conversation shows up as a second run without a second create.
resume_shellm() {
    local mode="$1"
    rm -rf "$WORK/stub"
    mkdir -p "$WORK/stub"
    LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE="$mode" SHELLM_API_FORMAT=responses \
        SHELLM_RESPONSES_CONVERSATION="${SHELLM_RESPONSES_CONVERSATION:-}" \
        "$WORK/toolbin/shellm" --resume --workdir "$WORK/wd" --max-iterations 3 "keep going" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# The shellm-run header row of the only trajectory this test wrote.
run_header() {
    cat "$HEADLONG_HOME"/trajectories/*/trajectory.jsonl 2>/dev/null \
        | jq -cR 'fromjson? | select(.type == "shellm-run")' 2>/dev/null | tail -1
}

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

# Conversation mode moves the history to the server: shellm creates one at
# run start, every call names it, and no response-id chain is kept.
rm -rf "$WORK/rstub"
SHELLM_RESPONSES_CONVERSATION=new run_shellm continue responses
rc=$?
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 2 && "$(create_calls)" -eq 1 \
      && "$(cat "$WORK/stub/conversation-1")" == conv_created \
      && "$(cat "$WORK/stub/conversation-2")" == conv_created \
      && -z "$(cat "$WORK/stub/previous-1")" \
      && -z "$(cat "$WORK/stub/previous-2")" \
      && ! -e "$WORK/stub/id-value-2" ]]; then
    ok "SHELLM_RESPONSES_CONVERSATION=new carries one conversation and no previous id"
else
    bad "SHELLM_RESPONSES_CONVERSATION=new carries one conversation and no previous id" "rc=$rc calls=$(main_calls) creates=$(create_calls) conv1=$(cat "$WORK/stub/conversation-1" 2>/dev/null) conv2=$(cat "$WORK/stub/conversation-2" 2>/dev/null) prev2=$(cat "$WORK/stub/previous-2" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

if grep -q 'conversations' "$WORK/rstub/create-args-1" \
   && grep -q '^create$' "$WORK/rstub/create-args-1" \
   && grep -q '^--metadata$' "$WORK/rstub/create-args-1"; then
    ok "the conversation is created through bin/responses"
else
    bad "the conversation is created through bin/responses" "$(tr '\n' ' ' < "$WORK/rstub/create-args-1" 2>/dev/null)"
fi

if [[ "$(run_header | jq -r '.conversation // empty')" == conv_created ]]; then
    ok "the conversation id is durable in the shellm-run header row"
else
    bad "the conversation id is durable in the shellm-run header row" "$(run_header)"
fi

if jq -e 'length == 1 and .[0].role == "user" and (.[0].content | contains("first output"))' \
        "$WORK/stub/messages-2.json" >/dev/null 2>&1; then
    ok "conversation mode sends only the new rows on later calls"
else
    bad "conversation mode sends only the new rows on later calls" "$(jq -c 'map(.content |= .[0:60])' "$WORK/stub/messages-2.json" 2>/dev/null)"
fi

# Resuming a run whose header carries a conversation reuses it: the operator
# still says "new", and the durable id is what "new" resolves to.
SHELLM_RESPONSES_CONVERSATION=new resume_shellm continue
rc=$?
if [[ "$rc" -eq 0 && "$(create_calls)" -eq 1 \
      && "$(cat "$WORK/stub/conversation-1")" == conv_created ]]; then
    ok "a resumed run reuses the conversation from its header instead of creating one"
else
    bad "a resumed run reuses the conversation from its header instead of creating one" "rc=$rc creates=$(create_calls) conv1=$(cat "$WORK/stub/conversation-1" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

# A literal id is used as given and never creates.
rm -rf "$WORK/rstub"
SHELLM_RESPONSES_CONVERSATION=conv_given run_shellm continue responses
rc=$?
if [[ "$rc" -eq 0 && "$(create_calls)" -eq 0 \
      && "$(cat "$WORK/stub/conversation-1")" == conv_given \
      && "$(run_header | jq -r '.conversation // empty')" == conv_given ]]; then
    ok "a literal conversation id skips the create and is recorded as given"
else
    bad "a literal conversation id skips the create and is recorded as given" "rc=$rc creates=$(create_calls) conv1=$(cat "$WORK/stub/conversation-1" 2>/dev/null) header=$(run_header)"
fi

# Server state the operator asked for has no safe local substitute, so a
# refused create ends the run before it spends a token.
rm -rf "$WORK/rstub"
RESPONSES_STUB_MODE=reject SHELLM_RESPONSES_CONVERSATION=new \
    run_shellm continue responses
rc=$?
if [[ "$rc" -ne 0 && "$(main_calls)" -eq 0 ]] \
   && grep -q 'could not create a Responses conversation' "$WORK/err" \
   && grep -q 'Conversation not found' "$WORK/err"; then
    ok "a refused conversation fails closed with the provider's message"
else
    bad "a refused conversation fails closed with the provider's message" "rc=$rc calls=$(main_calls) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

SHELLM_RESPONSES_CONVERSATION=new SHELLM_API_FORMAT=chat \
    "$WORK/toolbin/shellm" --help > "$WORK/out" 2> "$WORK/err"
rc=$?
if [[ "$rc" -ne 0 ]] \
   && grep -q 'SHELLM_RESPONSES_CONVERSATION needs SHELLM_API_FORMAT=responses' "$WORK/err"; then
    ok "a conversation under chat fails through shellm's error contract"
else
    bad "a conversation under chat fails through shellm's error contract" "rc=$rc stderr=$(cat "$WORK/err")"
fi

SHELLM_RESPONSES_CONVERSATION=resp_1 SHELLM_API_FORMAT=responses \
    "$WORK/toolbin/shellm" --help > "$WORK/out" 2> "$WORK/err"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'Invalid SHELLM_RESPONSES_CONVERSATION' "$WORK/err"; then
    ok "an id that is not a conversation is refused before the run starts"
else
    bad "an id that is not a conversation is refused before the run starts" "rc=$rc stderr=$(cat "$WORK/err")"
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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
