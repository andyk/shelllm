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

# Inspect the live run and durable home, including dotfiles. A failed inspector
# is an error, never evidence that Responses state is absent.
cat > "$WORK/check-chat-state" <<'CHECK'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${LLM_API_FORMAT:-}" != chat || -n "${LLM_PREVIOUS_RESPONSE_ID:-}" \
      || -n "${LLM_RESPONSE_FILE:-}" || -n "${LLM_RESPONSES_CONVERSATION:-}" ]]; then
    exit 1
fi
[[ -d "$1" && ! -L "$1" && -d "$2" && ! -L "$2" ]] || exit 2
if ! find "$1" "$2" \( -name .last_response.json -o -name .responses-sent-ids.json \
    -o -name .response-id -o -name .continuation-disabled -o -name .responses-replay.json \
    -o -name .responses-conversations -o -name responses-conversations \) -print > "$3"; then
    exit 2
fi
[[ ! -s "$3" ]]
CHECK
chmod +x "$WORK/check-chat-state"

mkdir -p "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
mv "$WORK/toolbin/context" "$WORK/toolbin/context.real"
cat > "$WORK/toolbin/context" <<'STUB'
#!/usr/bin/env bash
if [[ "${TEST_CONTEXT_FAIL:-0}" == 1 ]]; then
    echo "injected context renderer failure" >&2
    exit 91
fi
exec "$(dirname "$0")/context.real" "$@"
STUB
chmod +x "$WORK/toolbin/context"
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
    printf '%s\n' "${LLM_RESPONSES_CONVERSATION:-}" > "$LLM_STUB_DIR/summary-conversation"
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
printf '%s\n' "${LLM_RESPONSES_CONVERSATION-unset}" > "$LLM_STUB_DIR/conversation-$n"
printf '%s\n' "${LLM_RESPONSE_FILE:-}" > "$LLM_STUB_DIR/response-file-$n"
[[ -n "$messages_file" ]] && cp "$messages_file" "$LLM_STUB_DIR/messages-$n.json"
if [[ "${TEST_LOCK_PROBE:-0}" != 0 && "$n" == 1 ]]; then
    conversation_id="${LLM_RESPONSES_CONVERSATION:-}"
    checkpoint="$HEADLONG_HOME/trajectories/.responses-conversations/$conversation_id.json"
    cp "$checkpoint" "$LLM_STUB_DIR/checkpoint-before"
    mkdir -p "$LLM_STUB_DIR/contender"
    if [[ "$TEST_LOCK_PROBE" == cross-root ]]; then
        TEST_LOCK_PROBE=0 LLM_STUB_DIR="$LLM_STUB_DIR/contender" \
            SHELLM_TRAJ_DIR="$HEADLONG_HOME/other-trajectories" \
            SHELLM_RESPONSES_CONVERSATION="$conversation_id" \
            shellm --max-iterations 1 "contending input" </dev/null \
            > "$LLM_STUB_DIR/contender.out" 2> "$LLM_STUB_DIR/contender.err"
    elif [[ "$TEST_LOCK_PROBE" == equivalent-endpoint ]]; then
        TEST_LOCK_PROBE=0 LLM_STUB_DIR="$LLM_STUB_DIR/contender" \
            SHELLM_TRAJ_DIR="$HEADLONG_HOME/other-trajectories" \
            SHELLM_API_URL="https://api.openai.com/v1/responses/" \
            SHELLM_RESPONSES_CONVERSATION="$conversation_id" \
            shellm --max-iterations 1 "contending input" </dev/null \
            > "$LLM_STUB_DIR/contender.out" 2> "$LLM_STUB_DIR/contender.err"
    else
        TEST_LOCK_PROBE=0 LLM_STUB_DIR="$LLM_STUB_DIR/contender" \
            shellm --resume --max-iterations 1 "contending input" </dev/null \
            > "$LLM_STUB_DIR/contender.out" 2> "$LLM_STUB_DIR/contender.err"
    fi
    printf '%s\n' "$?" > "$LLM_STUB_DIR/contender.rc"
    cp "$checkpoint" "$LLM_STUB_DIR/checkpoint-after"
fi
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
            {id:("cmp_" + $id), type:"compaction", encrypted_content:"enc_server_compaction"},
            {id:("msg_" + $id), type:"message", role:"assistant", status:"completed", phase:"final_answer", content:[{type:"output_text", text:("text_" + $id)}]}
        ]
    }' > "$LLM_RESPONSE_FILE" )
}

case "$LLM_STUB_MODE:$n" in
    compact:1|compact-window:1|compact-malformed:1|compactfail:1|stateful-compact:1)
        write_response_usage resp_1 9000
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    compact:2|compact-window:2|compact-malformed:2|stateful-compact:2)
        write_response_usage resp_2 10
        printf '%s\n' '```bash' 'FINAL=done-after-compaction' '```'
        ;;
    compactfail:2)
        write_response_usage resp_2 9000
        printf '%s\n' '```bash' 'echo second' '```'
        ;;
    compactfail:3)
        write_response_usage resp_3 9000
        printf '%s\n' '```bash' 'FINAL=done-after-compaction' '```'
        ;;
    server-compaction:1|multiple-compactions:1)
        write_response_server_compacted resp_1
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    server-compaction-malformed:1)
        write_response resp_1
        jq '.output |= ([.[0], {id:"cmp_bad", type:"compaction"}, .[1]])' \
            "$LLM_RESPONSE_FILE" > "$LLM_RESPONSE_FILE.tmp"
        mv "$LLM_RESPONSE_FILE.tmp" "$LLM_RESPONSE_FILE"
        printf '%s\n' '```bash' 'printf "first output\n"' '```'
        ;;
    server-compaction:2)
        write_response resp_2
        printf '%s\n' '```bash' 'FINAL=done-after-server-compaction' '```'
        ;;
    server-compaction-malformed:2)
        write_response resp_2
        printf '%s\n' '```bash' 'FINAL=done-after-server-compaction' '```'
        ;;
    multiple-compactions:2)
        write_response_server_compacted resp_2
        printf '%s\n' '```bash' 'echo second' '```'
        ;;
    multiple-compactions:3)
        write_response resp_3
        printf '%s\n' '```bash' 'FINAL=done' '```'
        ;;
    nested:1)
        write_response resp_1
        printf '%s\n' '```bash' \
            'printf "%s|%s|%s|%s\n" "$SHELLM_RESPONSES_CONVERSATION" "$LLM_RESPONSES_CONVERSATION" "$LLM_PREVIOUS_RESPONSE_ID" "$SHELLM_API_TRANSPORT" > "$LLM_STUB_DIR/child-state"' \
            'FINAL=done' '```'
        ;;
    continue:1|fallback:1|stateless:1|unknown:1)
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
    unknown:2)
        ( umask 077; printf '%s' '{"error":{"message":"transport lost while continuing previous response","code":"outcome_unknown"}}' > "$LLM_RESPONSE_FILE" )
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
        chat_runs=( "${TEST_CHAT_TMP_ROOT:?}"/shellm-run.* )
        [[ "${#chat_runs[@]}" -eq 1 && -d "${chat_runs[0]}" ]] || exit 2
        printf '%s\n' "${chat_runs[0]}" > "$LLM_STUB_DIR/chat-rundir"
        if [[ "${TEST_CHAT_INJECT_RESPONSE_STATE:-0}" == 1 ]]; then
            : > "${chat_runs[0]}/.response-id"
        fi
        "${TEST_CHAT_STATE_CHECK:?}" "${chat_runs[0]}" "$HEADLONG_HOME" "$LLM_STUB_DIR/chat-state-paths"
        chat_state_rc=$?
        printf '%s\n' "$chat_state_rc" > "$LLM_STUB_DIR/chat-state-rc"
        [[ "$chat_state_rc" -eq 0 ]] || exit "$chat_state_rc"
        printf '%s\n' '```bash' 'FINAL=chat-done' '```'
        ;;
    *)
        echo "unexpected stub call $LLM_STUB_MODE:$n" >&2
        exit 2
        ;;
esac
STUB
chmod +x "$WORK/toolbin/llm"

# bin/responses, stubbed for both lifecycle calls shellm makes. `compact`
# records the window it was handed and answers with the canonical next window
# (one compaction item, nothing else); `conversations create` records the call
# and can refuse it, so the fail-closed path is exercised without a network.
cat > "$WORK/toolbin/responses" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
    compact)
        n=0
        [[ -f "$LLM_STUB_DIR/compact-calls" ]] && read -r n < "$LLM_STUB_DIR/compact-calls"
        n=$((n + 1))
        printf '%s\n' "$n" > "$LLM_STUB_DIR/compact-calls"
        model=""
        input_file=""
        provider=""
        instructions=""
        prev=""
        for arg in "$@"; do
            [[ "$prev" == --model ]] && model="$arg"
            [[ "$prev" == --input-file ]] && input_file="$arg"
            [[ "$prev" == --provider ]] && provider="$arg"
            [[ "$prev" == --instructions ]] && instructions="$arg"
            prev="$arg"
        done
        printf '%s\n' "$model" > "$LLM_STUB_DIR/compact-model-$n"
        printf '%s\n' "$provider" > "$LLM_STUB_DIR/compact-provider-$n"
        printf '%s\n' "$instructions" > "$LLM_STUB_DIR/compact-instructions-$n"
        [[ -n "$input_file" ]] && cp "$input_file" "$LLM_STUB_DIR/compact-input-$n.json"
        if [[ "$LLM_STUB_MODE" == compactfail ]]; then
            echo "responses: error: compaction is unavailable" >&2
            exit 1
        fi
        if [[ "$LLM_STUB_MODE" == compact-window ]]; then
            printf '%s\n' '{"output":[{"role":"user","content":"retained prefix"},{"type":"compaction","encrypted_content":"canonical"},{"role":"user","content":"retained suffix"}]}'
            exit 0
        fi
        if [[ "$LLM_STUB_MODE" == compact-malformed ]]; then
            printf '%s\n' '{"output":[{"type":"compaction"}]}'
            exit 0
        fi
        jq -nc '{
            id: "resp_compacted",
            object: "response",
            status: "completed",
            output: [{id: "cmp_1", type: "compaction", encrypted_content: "enc_compacted"}]
        }'
        ;;
    conversations)
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
        ;;
    *)
        echo "unexpected responses command ${1:-}" >&2
        exit 2
        ;;
esac
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
        "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations "${TEST_MAX_ITERATIONS:-3}" "do the task" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

main_calls() { cat "$WORK/stub/calls" 2>/dev/null || echo 0; }
compact_calls() { cat "$WORK/stub/compact-calls" 2>/dev/null || echo 0; }
create_calls() { cat "$WORK/rstub/creates" 2>/dev/null || echo 0; }
export RESPONSES_STUB_DIR="$WORK/rstub"

# Resume the run just made: same trajectory and the same create counter, so a
# reused conversation shows up as a second run without a second create.
resume_shellm() {
    local mode="$1"
    local resume_args=(--resume)
    [[ -z "${TEST_RESUME_TARGET:-}" ]] || resume_args=(--traj "$TEST_RESUME_TARGET")
    rm -rf "$WORK/stub"
    mkdir -p "$WORK/stub"
    LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE="$mode" SHELLM_API_FORMAT=responses \
        SHELLM_RESPONSES_CONVERSATION="${SHELLM_RESPONSES_CONVERSATION:-}" \
        "$WORK/toolbin/shellm" "${resume_args[@]}" --workdir "$WORK/wd" --max-iterations 3 "keep going" \
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

# Mentioning a previous response in an unknown-outcome diagnostic is not
# evidence of a pre-generation rejection.
run_shellm unknown responses
rc=$?
if [[ "$rc" -ne 0 && "$(main_calls)" -eq 2 ]] \
   && ! grep -q 'retrying once with exact replay' "$WORK/err"; then
    ok "unknown continuation outcome never falls back to a new create"
else
    bad "unknown continuation outcome never falls back to a new create" "rc=$rc calls=$(main_calls)"
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
if jq -e 'all(.[]; .role != "assistant" and (.content | contains("do the task") or contains("first output") | not))
          and any(.[]; .content | contains("keep going"))' "$WORK/stub/messages-1.json" >/dev/null; then
    ok "Conversation resume does not reappend the old prompt, delivered output, or assistant turns"
else
    bad "Conversation resume does not reappend the old prompt, delivered output, or assistant turns"
fi

# Empty/unset is also resume, not a silent switch to a fresh response chain.
resume_shellm continue
rc=$?
if [[ "$rc" == 0 && "$(cat "$WORK/stub/conversation-1")" == conv_created ]] \
    && jq -e 'all(.[]; .role != "assistant" and (.content | contains("do the task") | not))' \
        "$WORK/stub/messages-1.json" >/dev/null; then
    ok "default environment resumes the Conversation and its sent-step acknowledgement"
else
    bad "default environment resumes the Conversation and its sent-step acknowledgement"
fi

checkpoint="$HEADLONG_HOME/trajectories/.responses-conversations/conv_created.json"
mode=$(stat -c %a "$checkpoint" 2>/dev/null || stat -f %Lp "$checkpoint" 2>/dev/null)
if [[ "$mode" == 600 ]] && jq -e '.state == "ready" and .version == 1
    and (.sent | length > 0) and (.trajectory | endswith("trajectory.jsonl"))' "$checkpoint" >/dev/null; then
    ok "durable acknowledgement is mode 0600 and binds the actual trajectory"
else
    bad "durable acknowledgement is mode 0600 and binds the actual trajectory"
fi

SHELLM_RESPONSES_CONVERSATION=conv_different resume_shellm continue
rc=$?
if [[ "$rc" == 0 && "$(cat "$WORK/stub/conversation-1")" == conv_different ]] \
    && jq -e 'any(.[]; .content | contains("do the task")) and any(.[]; .role == "assistant")' \
        "$WORK/stub/messages-1.json" >/dev/null; then
    ok "a different Conversation receives the initial rendered history, not the old acknowledgement"
else
    bad "a different Conversation receives the initial rendered history, not the old acknowledgement"
fi

# The last execution output is genuinely unsent when an iteration limit ends
# the run. It must survive resume even though earlier input was acknowledged.
TEST_MAX_ITERATIONS=1 SHELLM_RESPONSES_CONVERSATION=conv_unsent run_shellm continue responses
resume_shellm continue
rc=$?
if [[ "$rc" == 0 ]] && jq -e 'any(.[]; .content | contains("first output"))
    and any(.[]; .content | contains("keep going"))
    and all(.[]; .role != "assistant" and (.content | contains("do the task") | not))' \
    "$WORK/stub/messages-1.json" >/dev/null; then
    ok "resume preserves genuinely unsent last tool output"
else
    bad "resume preserves genuinely unsent last tool output"
fi

TEST_LOCK_PROBE=1 SHELLM_RESPONSES_CONVERSATION=conv_locked run_shellm continue responses
rc=$?
if [[ "$rc" == 0 && "$(cat "$WORK/stub/contender.rc")" != 0 \
    && ! -e "$WORK/stub/contender/calls" ]] \
    && cmp -s "$WORK/stub/checkpoint-before" "$WORK/stub/checkpoint-after" \
    && jq -e '.state == "in_flight"' "$WORK/stub/checkpoint-before" >/dev/null; then
    ok "a concurrent run cannot dispatch or overwrite the in-flight acknowledgement"
else
    bad "a concurrent run cannot dispatch or overwrite the in-flight acknowledgement"
fi

checkpoint="$HEADLONG_HOME/trajectories/.responses-conversations/conv_locked.json"
trajectory=$(jq -r .trajectory "$checkpoint")
jq -nc 'range(0;60) | {type:"observation",step_id:("padding-" + tostring)}' >> "$trajectory"
TEST_RESUME_TARGET="$(basename "$(dirname "$trajectory")")" resume_shellm continue
if [[ "$?" == 0 && "$(cat "$WORK/stub/conversation-1")" == conv_locked ]] \
    && jq -e 'all(.[]; .content | contains("do the task") | not)' "$WORK/stub/messages-1.json" >/dev/null; then
    ok "trajectory aliases and a header beyond the last 50 rows restore the same acknowledgement"
else
    bad "trajectory aliases and a header beyond the last 50 rows restore the same acknowledgement"
fi

cp "$checkpoint" "$WORK/checkpoint-locked"
lock_identity=$(jq -c '[.provider,.endpoint,.conversation]' "$checkpoint")
if command -v sha256sum >/dev/null 2>&1; then
    lock_digest=$(printf '%s' "$lock_identity" | sha256sum)
else
    lock_digest=$(printf '%s' "$lock_identity" | shasum -a 256)
fi
lock_digest=${lock_digest%%[[:space:]]*}
lock_path="$HEADLONG_HOME/run/responses-conversations/conv_locked-$lock_digest.lock"
mkdir "$lock_path"
resume_shellm continue
if [[ "$?" != 0 && "$(main_calls)" == 0 && -d "$lock_path" ]] \
    && cmp -s "$checkpoint" "$WORK/checkpoint-locked"; then
    ok "a stale crash lock is never stolen or released by a contender"
else
    bad "a stale crash lock is never stolen or released by a contender"
fi
rmdir "$lock_path"

LLM_PROVIDER=openai-compatible resume_shellm continue
if [[ "$?" != 0 && "$(main_calls)" == 0 ]] && cmp -s "$checkpoint" "$WORK/checkpoint-locked"; then
    ok "changing the effective provider cannot reuse or overwrite a Conversation acknowledgement"
else
    bad "changing the effective provider cannot reuse or overwrite a Conversation acknowledgement"
fi

LLM_STUB_DIR="$WORK/stub" LLM_STUB_MODE=continue SHELLM_API_FORMAT=responses \
    SHELLM_RESPONSES_CONVERSATION=conv_locked "$WORK/toolbin/shellm" \
    --workdir "$WORK/wd" --max-iterations 1 "another trajectory" \
    </dev/null > "$WORK/out" 2> "$WORK/err"
if [[ "$?" != 0 && "$(main_calls)" == 0 ]] && cmp -s "$checkpoint" "$WORK/checkpoint-locked"; then
    ok "a different trajectory cannot overwrite a shared Conversation acknowledgement"
else
    bad "a different trajectory cannot overwrite a shared Conversation acknowledgement"
fi

TEST_LOCK_PROBE=cross-root SHELLM_RESPONSES_CONVERSATION=conv_cross_root \
    run_shellm continue responses
rc=$?
if [[ "$rc" == 0 && "$(cat "$WORK/stub/contender.rc")" != 0 \
    && ! -e "$WORK/stub/contender/calls" ]] \
    && cmp -s "$WORK/stub/checkpoint-before" "$WORK/stub/checkpoint-after" \
    && grep -q 'Conversation is locked' "$WORK/stub/contender.err"; then
    ok "a Conversation lock holds across different trajectory roots"
else
    bad "a Conversation lock holds across different trajectory roots" "rc=$rc contender=$(cat "$WORK/stub/contender.rc" 2>/dev/null) calls=$(cat "$WORK/stub/contender/calls" 2>/dev/null) stderr=$(tail -3 "$WORK/stub/contender.err" 2>/dev/null | tr '\n' ' ')"
fi

TEST_LOCK_PROBE=equivalent-endpoint \
    SHELLM_RESPONSES_CONVERSATION=conv_equivalent_endpoint run_shellm continue responses
rc=$?
if [[ "$rc" == 0 && "$(cat "$WORK/stub/contender.rc")" != 0 \
    && ! -e "$WORK/stub/contender/calls" ]] \
    && cmp -s "$WORK/stub/checkpoint-before" "$WORK/stub/checkpoint-after" \
    && grep -q 'Conversation is locked' "$WORK/stub/contender.err"; then
    ok "an explicit default endpoint shares the unset endpoint's Conversation lock"
else
    bad "an explicit default endpoint shares the unset endpoint's Conversation lock" "rc=$rc contender=$(cat "$WORK/stub/contender.rc" 2>/dev/null) calls=$(cat "$WORK/stub/contender/calls" 2>/dev/null) stderr=$(tail -3 "$WORK/stub/contender.err" 2>/dev/null | tr '\n' ' ')"
fi

SHELLM_RESPONSES_CONVERSATION=conv_unknown run_shellm no-terminal responses
checkpoint="$HEADLONG_HOME/trajectories/.responses-conversations/conv_unknown.json"
cp "$checkpoint" "$WORK/checkpoint-unknown"
resume_shellm continue
rc=$?
if [[ "$rc" != 0 && "$(main_calls)" == 0 ]] \
    && jq -e '.state == "in_flight" and .sent == {}' "$checkpoint" >/dev/null \
    && cmp -s "$checkpoint" "$WORK/checkpoint-unknown"; then
    ok "ambiguous delivery remains unacknowledged and resume fails closed without resending"
else
    bad "ambiguous delivery remains unacknowledged and resume fails closed without resending"
fi

SHELLM_RESPONSES_CONVERSATION=conv_context_fail run_shellm continue responses
checkpoint="$HEADLONG_HOME/trajectories/.responses-conversations/conv_context_fail.json"
cp "$checkpoint" "$WORK/checkpoint-context-fail"
TEST_CONTEXT_FAIL=1 resume_shellm continue
rc=$?
if [[ "$rc" != 0 && "$(main_calls)" == 0 ]] \
    && cmp -s "$checkpoint" "$WORK/checkpoint-context-fail" \
    && grep -q 'could not render Conversation context' "$WORK/err"; then
    ok "Conversation context rendering fails closed before dispatch or acknowledgement"
else
    bad "Conversation context rendering fails closed before dispatch or acknowledgement" "rc=$rc calls=$(main_calls) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

SHELLM_RESPONSES_CONVERSATION=conv_missing run_shellm continue responses
rm "$HEADLONG_HOME/trajectories/.responses-conversations/conv_missing.json"
resume_shellm continue
if [[ "$?" != 0 && "$(main_calls)" == 0 ]] && grep -q 'acknowledgement is missing' "$WORK/err"; then
    ok "a missing acknowledgement for a previously used Conversation fails closed"
else
    bad "a missing acknowledgement for a previously used Conversation fails closed"
fi

SHELLM_RESPONSES_CONVERSATION=conv_nested run_shellm nested responses
if [[ "$?" == 0 && "$(cat "$WORK/stub/child-state")" == '|||https' \
    && -z "$(cat "$WORK/stub/summary-conversation")" ]]; then
    ok "generated code and summaries do not silently share the parent's Conversation"
else
    bad "generated code and summaries do not silently share the parent's Conversation"
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

# Default chat mode must be inspected in the llm stub while its run still exists.
mkdir -p "$WORK/chat-tmp"
TMPDIR="$WORK/chat-tmp" TEST_CHAT_TMP_ROOT="$WORK/chat-tmp" \
    TEST_CHAT_STATE_CHECK="$WORK/check-chat-state" run_shellm chat chat
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stub/format-1")" == chat \
      && -z "$(cat "$WORK/stub/previous-1")" \
      && "$(cat "$WORK/stub/chat-state-rc")" == 0 ]]; then
    ok "default chat mode remains stateless"
else
    bad "default chat mode remains stateless" "rc=$rc format=$(cat "$WORK/stub/format-1")"
fi

# A state file created in the actual live rundir must fail before cleanup hides it.
TMPDIR="$WORK/chat-tmp" TEST_CHAT_TMP_ROOT="$WORK/chat-tmp" \
    TEST_CHAT_STATE_CHECK="$WORK/check-chat-state" TEST_CHAT_INJECT_RESPONSE_STATE=1 \
    run_shellm chat chat
rc=$?
if [[ "$rc" -ne 0 && "$(cat "$WORK/stub/chat-state-rc")" == 1 \
      && -s "$WORK/stub/chat-state-paths" ]]; then
    ok "chat oracle rejects an injected live Responses state file before cleanup"
else
    bad "chat oracle rejects an injected live Responses state file before cleanup" "rc=$rc"
fi

# Exercise the same inspector against every source-owned state name and config.
chat_probe="$WORK/chat-oracle-control"
mkdir -p "$chat_probe/run" "$chat_probe/home" "$chat_probe/no-tools"
check_chat_probe() {
    LLM_API_FORMAT="${1:-chat}" LLM_PREVIOUS_RESPONSE_ID="${2:-}" \
        LLM_RESPONSE_FILE="${3:-}" LLM_RESPONSES_CONVERSATION="${4:-}" \
        "$WORK/check-chat-state" "$chat_probe/run" "$chat_probe/home" "$chat_probe/found"
}
if check_chat_probe; then
    ok "chat oracle accepts an inspected empty run and home"
else
    bad "chat oracle accepts an inspected empty run and home"
fi
for state_name in .last_response.json .responses-sent-ids.json .response-id \
    .continuation-disabled .responses-replay.json; do
    : > "$chat_probe/run/$state_name"
    check_chat_probe
    probe_rc=$?
    if [[ "$probe_rc" -eq 1 ]]; then
        ok "chat oracle rejects transient state $state_name"
    else
        bad "chat oracle rejects transient state $state_name" "rc=$probe_rc"
    fi
    rm "$chat_probe/run/$state_name"
done
for state_path in trajectories/.responses-conversations run/responses-conversations; do
    mkdir -p "$chat_probe/home/$state_path"
    check_chat_probe
    probe_rc=$?
    if [[ "$probe_rc" -eq 1 ]]; then
        ok "chat oracle rejects durable state $state_path"
    else
        bad "chat oracle rejects durable state $state_path" "rc=$probe_rc"
    fi
    rm -rf "${chat_probe:?}/home/${state_path:?}"
done
for state_field in format previous response conversation; do
    probe_format=chat; probe_previous=""; probe_response=""; probe_conversation=""
    case "$state_field" in
        format) probe_format=responses ;;
        previous) probe_previous=resp_forbidden ;;
        response) probe_response="$chat_probe/forbidden-response.json" ;;
        conversation) probe_conversation=conv_forbidden ;;
    esac
    check_chat_probe "$probe_format" "$probe_previous" "$probe_response" "$probe_conversation"
    probe_rc=$?
    if [[ "$probe_rc" -eq 1 ]]; then
        ok "chat oracle rejects Responses configuration $state_field"
    else
        bad "chat oracle rejects Responses configuration $state_field" "rc=$probe_rc"
    fi
done
PATH="$chat_probe/no-tools" LLM_API_FORMAT=chat LLM_PREVIOUS_RESPONSE_ID='' \
    LLM_RESPONSE_FILE='' LLM_RESPONSES_CONVERSATION='' \
    /bin/bash "$WORK/check-chat-state" "$chat_probe/run" "$chat_probe/home" "$chat_probe/found" \
    > "$chat_probe/missing-tool.out" 2> "$chat_probe/missing-tool.err"
probe_rc=$?
if [[ "$probe_rc" -eq 2 ]]; then
    ok "chat oracle fails closed when its inspection tool is unavailable"
else
    bad "chat oracle fails closed when its inspection tool is unavailable" "rc=$probe_rc"
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
if [[ "$rc" -eq 0 && "$(main_calls)" -eq 3 && "$(compact_calls)" -eq 1 ]] \
   && jq -e 'any(.[]; .encrypted_content == "enc_resp_1")' "$WORK/stub/messages-2.json" >/dev/null 2>&1 \
   && grep -q 'compaction failed' "$WORK/err"; then
    ok "a failed compact call warns, keeps the chain, and is not repeated on later crossings"
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

run_shellm server-compaction-malformed responses openrouter openai/o4-mini
if [[ "$?" == 0 ]] \
   && jq -e 'any(.[]; .encrypted_content == "enc_resp_1")
        and all(.[]; .id? != "cmp_bad")' \
        "$WORK/stub/messages-2.json" >/dev/null 2>&1 \
   && grep -q 'unusable compaction item' "$WORK/err"; then
    ok "an unusable server compaction marker cannot prune known-good replay"
else
    bad "an unusable server compaction marker cannot prune known-good replay" "m2=$(jq -c 'map(.type // .role)' "$WORK/stub/messages-2.json" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi

run_shellm multiple-compactions responses openrouter openai/o4-mini
if [[ "$?" == 0 ]] && jq -e '.[0].id == "cmp_resp_2"
    and all(.[]; .id != "cmp_resp_1" and .id != "msg_resp_1")
    and any(.[]; .content? | strings | contains("second"))' "$WORK/stub/messages-3.json" >/dev/null; then
    ok "repeated server compaction prunes to the most recent marker"
else
    bad "repeated server compaction prunes to the most recent marker"
fi

SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 run_shellm compact-window responses openrouter openai/o4-mini
if [[ "$?" == 0 ]] && jq -e '.[0:3] == [{role:"user",content:"retained prefix"},
    {type:"compaction",encrypted_content:"canonical"},{role:"user",content:"retained suffix"}]' \
    "$WORK/stub/messages-2.json" >/dev/null; then
    ok "standalone compact.output is preserved as-is including items before the marker"
else
    bad "standalone compact.output is preserved as-is including items before the marker"
fi

SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 run_shellm compact-malformed responses openrouter openai/o4-mini
if [[ "$?" == 0 && "$(compact_calls)" == 1 ]] \
    && jq -e 'any(.[]; .encrypted_content == "enc_resp_1")' \
        "$WORK/stub/messages-2.json" >/dev/null 2>&1 \
    && grep -q 'unusable compaction item' "$WORK/err"; then
    ok "an unusable standalone compact reply keeps known-good replay"
else
    bad "an unusable standalone compact reply keeps known-good replay" "calls=$(compact_calls) m2=$(jq -c 'map(.type // .role)' "$WORK/stub/messages-2.json" 2>/dev/null) stderr=$(tail -3 "$WORK/err" | tr '\n' ' ')"
fi
if [[ "$(cat "$WORK/stub/compact-provider-1")" == openrouter \
    && -s "$WORK/stub/compact-instructions-1" ]]; then
    ok "standalone lifecycle call names the effective provider and supplies system instructions"
else
    bad "standalone lifecycle call names the effective provider and supplies system instructions"
fi

printf '%s\n' '{"store":false}' > "$WORK/body.json"
SHELLM_RESPONSES_BODY_FILE="$WORK/body.json" SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 \
    run_shellm stateful-compact responses openai
if [[ "$?" == 0 && "$(compact_calls)" == 0 \
    && "$(cat "$WORK/stub/threshold-1")" == 1000 && "$(cat "$WORK/stub/threshold-2")" == 1000 \
    && -z "$(cat "$WORK/stub/previous-2")" ]] \
    && jq -e 'any(.[]; .encrypted_content == "enc_resp_1")' "$WORK/stub/messages-2.json" >/dev/null; then
    ok "native OpenAI store=false uses stateless replay with server compaction"
else
    bad "native OpenAI store=false uses stateless replay with server compaction"
fi

SHELLM_RESPONSES_COMPACT_MODE=server SHELLM_RESPONSES_COMPACT_THRESHOLD=1000 \
    run_shellm stateful-compact responses openai-compatible
if [[ "$?" == 0 && "$(compact_calls)" == 0 && "$(cat "$WORK/stub/threshold-1")" == 1000 ]]; then
    ok "a compatible endpoint can explicitly declare server compaction support"
else
    bad "a compatible endpoint can explicitly declare server compaction support"
fi

for body in '{"conversation":"conv_body"}' '{"conversation":{"id":"conv_body"}}'; do
    printf '%s\n' "$body" > "$WORK/body.json"
    rm -rf "$WORK/rstub"
    SHELLM_RESPONSES_BODY_FILE="$WORK/body.json" SHELLM_RESPONSES_CONVERSATION=new \
        run_shellm continue responses
    if [[ "$?" != 0 && "$(main_calls)" == 0 && "$(create_calls)" == 0 ]] \
        && grep -q 'use SHELLM_RESPONSES_CONVERSATION' "$WORK/err"; then
        ok "body-file Conversation is refused before spending: $body"
    else
        bad "body-file Conversation is refused before spending: $body"
    fi
done

# Exercise the actual upkeep function without a model, so elapsed completion
# time can be pinned rather than relying on slow wall-clock test fixtures.
if (
    eval "$(sed -n '/^has_usable_compaction_window() {/,/^}/p' "$REPO/bin/shellm")"
    eval "$(sed -n '/^compact_replay_chain() {/,/^}/p' "$REPO/bin/shellm")"
    progress() { :; }
    responses() { printf '%s' "$LLM_MAX_TIME" > "$WORK/compact-budget"; printf '{"output":[{"type":"compaction","encrypted_content":"opaque"}]}'; }
    _SHELLM_COMPACT_MODE=standalone
    _SHELLM_HOST_PROVIDER=openai
    # Used by the sourced upkeep function above.
    # shellcheck disable=SC2034
    SHELLM_RESPONSES_COMPACT_THRESHOLD=10
    # shellcheck disable=SC2034
    system_prompt="test"
    mkdir -p "$WORK/compact-deadline"
    replay="$WORK/compact-deadline/replay"
    printf '[]' > "$replay"
    printf '{"usage":{"input_tokens":100}}' > "$WORK/compact-response"
    LLM_MAX_TIME=1
    _call_started=$((SECONDS-2))
    compact_replay_chain "$replay" "$WORK/compact-response" 1
    [[ ! -e "$WORK/compact-budget" ]] || exit 1
    LLM_MAX_TIME=100
    _call_started=$((SECONDS-5))
    compact_replay_chain "$replay" "$WORK/compact-response" 1
    [[ "$(cat "$WORK/compact-budget")" -gt 0 \
        && "$(cat "$WORK/compact-budget")" -le 95 ]] || exit 1
    jq -e 'length == 1 and .[0].type == "compaction"
        and .[0].encrypted_content == "opaque"' "$replay" >/dev/null
); then
    ok "standalone compaction only spends remaining completion deadline budget"
else
    bad "standalone compaction only spends remaining completion deadline budget"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
