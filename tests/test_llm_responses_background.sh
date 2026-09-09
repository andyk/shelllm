#!/usr/bin/env bash
# test_llm_responses_background.sh — background Responses in bin/llm: polling,
# stream resume from the last sequence number, and cancel on signal, deadline,
# and exhausted resumes (design/responses-lifecycle.md).
#
# curl is stubbed. $CURL_MODE_FILE holds one mode per line; line N applies to
# call N and the last line repeats. Every call's argv is recorded, so tests pin
# the exact URLs, verbs, and payloads of the create, the polls, the resume, and
# the cancel.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/bin" "$WORK/home" "$WORK/calls"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$CURL_DIR/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$CURL_DIR/count"
printf '%s\n' "$@" > "$CURL_DIR/args-$n"
mode=$(sed -n "${n}p" "$CURL_MODE_FILE")
[[ -z "$mode" ]] && mode=$(tail -1 "$CURL_MODE_FILE")
out_file=""
prev=""
for a in "$@"; do
    [[ "$prev" == "-o" ]] && out_file="$a"
    [[ "$prev" == "-d" && "$a" == @* ]] && cp "${a#@}" "$CURL_DIR/payload-$n"
    prev="$a"
done
# The URL is always the last argument; a cancel is answered 200 whatever the
# mode says, since the mode describes the response being polled.
url="${*: -1}"
if [[ "$url" == */cancel ]]; then
    printf 'cancelled\n' >> "$CURL_DIR/cancels"
    if [[ "${CANCEL_FAIL:-0}" == 1 ]]; then
        printf '%s' '{"error":{"message":"cancel unavailable"}}' > "$out_file"
        printf '500'
        exit 0
    fi
    printf '%s' '{"id":"resp_bg","status":"cancelled","output":[]}' > "$out_file"
    printf '200'
    exit 0
fi

completed='{"id":"resp_bg","object":"response","status":"completed","output":[{"id":"msg_bg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"done"}]}],"usage":{"input_tokens":11,"output_tokens":2}}'
if [[ "${CURL_DELAY:-0}" != 0 ]]; then
    printf '{"call":%d,"mode":"%s","phase":"delay-entered","epoch_seconds":%s}\n' \
        "$n" "$mode" "$(date +%s)" >> "$CURL_DIR/delay-phases.jsonl"
    sleep "$CURL_DELAY"
    printf '{"call":%d,"mode":"%s","phase":"delay-released","epoch_seconds":%s}\n' \
        "$n" "$mode" "$(date +%s)" >> "$CURL_DIR/delay-phases.jsonl"
fi
case "$mode" in
    stream-fixture)
        cat "$CURL_STREAM_FIXTURE"
        ;;
    poll-error)
        printf '%s' '{"error":{"message":"backend failed"}}' > "$out_file"
        printf '200'
        ;;
    poll-invalid)
        printf '%s' '{"id":"resp_bg","status":"unexpected","output":[]}' > "$out_file"
        printf '200'
        ;;
    create-lost)
        exit 28
        ;;
    stream-cancelled)
        printf 'data: %s\n\n' '{"type":"response.cancelled","sequence_number":4,"response":{"id":"resp_bg","status":"cancelled","output":[]}}'
        ;;
    create-queued)
        printf '%s' '{"id":"resp_bg","object":"response","status":"queued","output":[]}' > "$out_file"
        printf '200'
        ;;
    poll-in-progress)
        printf '%s' '{"id":"resp_bg","object":"response","status":"in_progress","output":[]}' > "$out_file"
        printf '200'
        ;;
    poll-completed)
        printf '%s' "$completed" > "$out_file"
        printf '200'
        ;;
    poll-cancelled)
        printf '%s' '{"id":"resp_bg","object":"response","status":"cancelled","output":[]}' > "$out_file"
        printf '200'
        ;;
    poll-500)
        printf '%s' '{"error":{"message":"boom"}}' > "$out_file"
        printf '500'
        ;;
    chat-ok)
        printf '%s' '{"choices":[{"message":{"content":"ok"}}]}' > "$out_file"
        printf '200'
        ;;
    stream-created-drop)
        printf 'data: %s\n\n' '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"queued","output":[]}}'
        printf 'data: %s\n\n' '{"type":"response.in_progress","sequence_number":1,"response":{"id":"resp_bg","status":"in_progress","output":[]}}'
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":2,"delta":"a"}'
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":3,"delta":"b"}'
        ;;
    stream-created-only)
        printf 'data: %s\n\n' '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"queued","output":[]}}'
        ;;
    stream-resume-complete)
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":4,"delta":"!"}'
        printf 'data: %s\n\n' '{"type":"response.completed","sequence_number":5,"response":{"id":"resp_bg","object":"response","status":"completed","output":[{"id":"msg_bg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ab!"}]}],"usage":{"input_tokens":11,"output_tokens":3}}}'
        ;;
    stream-resume-terminal-only)
        printf 'data: %s\n\n' '{"type":"response.completed","sequence_number":4,"response":{"id":"resp_bg","object":"response","status":"completed","output":[{"id":"msg_bg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ab"}]}],"usage":{"input_tokens":11,"output_tokens":2}}}'
        ;;
    stream-empty)
        :
        ;;
    stream-complete)
        printf 'data: %s\n\n' '{"type":"response.created","sequence_number":0,"response":{"id":"resp_fg","status":"in_progress","output":[]}}'
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":1,"delta":"ok"}'
        printf 'data: %s\n\n' '{"type":"response.completed","sequence_number":2,"response":{"id":"resp_fg","object":"response","status":"completed","output":[{"id":"msg_fg","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":5,"output_tokens":1}}}'
        ;;
    stream-bg-block)
        printf 'data: %s\n\n' '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}'
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":1,"delta":"```bash\necho hi\n```\n"}'
        printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":2,"delta":"trailing prose that costs tokens"}'
        printf 'data: %s\n\n' '{"type":"response.completed","sequence_number":3,"response":{"id":"resp_bg","object":"response","status":"completed","output":[],"usage":{"input_tokens":5,"output_tokens":9}}}'
        ;;
    *)
        echo "curl stub: unknown mode '$mode' for call $n" >&2
        exit 2
        ;;
esac
STUB
chmod +x "$WORK/bin/curl"

export PATH="$WORK/bin:$PATH"
export HEADLONG_HOME="$WORK/home"
export OPENAI_API_KEY="test-openai-key"
export LLM_RETRY_BACKOFF=0
export LLM_RESPONSES_POLL_INTERVAL=0
export CURL_DIR="$WORK/calls"
export CURL_MODE_FILE="$WORK/modes"
LLM="$REPO/bin/llm"

reset() {
    rm -rf "$CURL_DIR"; mkdir -p "$CURL_DIR"
    printf '%s\n' "$1" > "$CURL_MODE_FILE"
    rm -f "$WORK/response.json" "$WORK/usage.json" "$WORK/stdout" "$WORK/stderr"
}
calls()   { cat "$CURL_DIR/count" 2>/dev/null || echo 0; }
url_of()  { tail -1 "$CURL_DIR/args-$1" 2>/dev/null; }
has_arg() { grep -qxF -- "$2" "$CURL_DIR/args-$1" 2>/dev/null; }
cancels() { cat "$CURL_DIR/cancels" 2>/dev/null | wc -l | tr -d ' '; }
cancel_url() {
    local f u
    for f in "$CURL_DIR"/args-*; do
        u=$(tail -1 "$f")
        [[ "$u" == */cancel ]] && { printf '%s' "$u"; return 0; }
    done
    return 1
}

run_bg() {
    LLM_API_FORMAT=responses \
    LLM_RESPONSE_FILE="$WORK/response.json" \
    LLM_USAGE_FILE="$WORK/usage.json" \
    "$LLM" --provider openai -m gpt-5.4-mini "$@"
}

export CURL_STREAM_FIXTURE="$WORK/stream-fixture"
stream_events() {
    printf 'data: %s\n\n' "$@" > "$CURL_STREAM_FIXTURE"
}

# Initial stream errors still leave the accepted background job running.
# A permanent generic error is not evidence that the job reached a terminal.
for error in transient permanent after-text; do
    for cancel_fail in 0 1; do
        reset stream-fixture
        stream_events '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}'
        if [[ "$error" == after-text ]]; then
            printf 'data: %s\n\n' '{"type":"response.output_text.delta","sequence_number":1,"delta":"partial"}' >> "$CURL_STREAM_FIXTURE"
        fi
        if [[ "$error" == permanent ]]; then
            printf 'data: %s\n\n' '{"type":"error","error":{"param":"previous_response_id","message":"previous response rejected"}}' >> "$CURL_STREAM_FIXTURE"
        else
            printf 'data: %s\n\n' '{"type":"error","error":{"message":"synthetic stream failure"}}' >> "$CURL_STREAM_FIXTURE"
        fi
        CANCEL_FAIL="$cancel_fail" LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
        rc=$?
        expected_status=cancelled
        [[ "$cancel_fail" == 0 ]] || expected_status=unknown
        if [[ "$rc" -ne 0 && "$(calls)" -eq 2 && "$(cancels)" -eq 1 ]] \
           && [[ "$(cancel_url)" == "https://api.openai.com/v1/responses/resp_bg/cancel" ]] \
           && jq -e --arg status "$expected_status" '.id == "resp_bg"
                and (if $status == "unknown" then .error.code == "outcome_unknown"
                     and .cancellation.requested == true else .status == $status end)' "$WORK/response.json" >/dev/null; then
            ok "initial $error stream failure cancels once and records $expected_status"
        else
            bad "initial $error stream failure cancels once and records $expected_status" "rc=$rc calls=$(calls) cancels=$(cancels) stderr=$(cat "$WORK/stderr")"
        fi
    done
done

for terminal in cancelled failed; do
    reset stream-fixture
    stream_events '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}' \
        "{\"type\":\"response.$terminal\",\"sequence_number\":1,\"response\":{\"id\":\"resp_bg\",\"status\":\"$terminal\",\"output\":[]}}"
    LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && "$(calls)" -eq 1 && "$(cancels)" -eq 0 ]] \
       && jq -e --arg status "$terminal" '.id == "resp_bg" and .status == $status' "$WORK/response.json" >/dev/null; then
        ok "validated $terminal terminal is not cancelled again"
    else
        bad "validated $terminal terminal is not cancelled again" "rc=$rc calls=$(calls) cancels=$(cancels)"
    fi
done

# Every advertised identity is checked before its text can escape. Invalid
# terminal envelopes must not suppress cancellation of the known response.
for invalid in \
    '{"type":"response.output_text.delta","sequence_number":1,"response_id":"resp_other","delta":"FOREIGN"}' \
    '{"type":"response.output_text.delta","sequence_number":1,"response_id":null,"delta":"FOREIGN"}' \
    '{"type":"response.output_text.delta","sequence_number":1,"response_id":"resp_other","response":{"id":"resp_bg"},"delta":"FOREIGN"}' \
    '{"type":"response.cancelled","sequence_number":1,"response":{"id":"resp_bg","status":"in_progress","output":[]}}' \
    '{"type":"response.failed","sequence_number":1}' \
    '{"type":"response.cancelled","sequence_number":1}' \
    '{"type":"response.cancelled","sequence_number":1,"response":{"id":"resp_bg","status":"cancelled"}}' \
    'not-json' '[]' '{"type":"response.output_text.delta","delta":"FOREIGN"} {}'; do
    reset stream-fixture
    stream_events '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}' \
        "$invalid" '{"type":"response.completed","sequence_number":2,"response":{"id":"resp_bg","status":"completed","output":[]}}'
    CANCEL_FAIL=1 LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && ! -s "$WORK/stdout" && "$(calls)" -eq 2 && "$(cancels)" -eq 1 ]] \
       && jq -e '.id == "resp_bg" and .error.code == "outcome_unknown" and .cancellation.requested == true' "$WORK/response.json" >/dev/null; then
        ok "invalid stream event fails before output and cancels the known response: $invalid"
    else
        bad "invalid stream event fails before output and cancels the known response: $invalid" "rc=$rc calls=$(calls) cancels=$(cancels) out=$(cat "$WORK/stdout")"
    fi
done

# The resume cursor follows the highest accepted sequence in the current
# stream, not only the floor supplied at the start of a resumed stream.
reset $'stream-fixture\nstream-resume-complete'
stream_events '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}' \
    '{"type":"response.output_text.delta","sequence_number":2,"response_id":"resp_bg","delta":"a"}' \
    '{"type":"response.output_text.delta","sequence_number":2,"response_id":"resp_bg","delta":"DUPLICATE"}' \
    '{"type":"response.output_text.delta","sequence_number":1,"response_id":"resp_bg","delta":"BACKWARD"}' \
    '{"type":"response.output_text.delta","sequence_number":3,"response_id":"resp_bg","delta":"b"}' \
    '{"type":"response.output_text.delta","sequence_number":2,"response_id":"resp_bg","delta":"BACKWARD"}'
LLM_RETRIES=1 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == 'ab!' && "$(calls)" -eq 2 && "$(cancels)" -eq 0 ]] \
   && [[ "$(url_of 2)" == "https://api.openai.com/v1/responses/resp_bg?stream=true&starting_after=3" ]]; then
    ok "duplicate and out-of-order sequences cannot repeat text or move the resume cursor backwards"
else
    bad "duplicate and out-of-order sequences cannot repeat text or move the resume cursor backwards" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout") resume=$(url_of 2)"
fi
reset $'stream-created-only\nstream-fixture\nstream-resume-complete'
LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == 'ab!' && "$(calls)" -eq 3 && "$(cancels)" -eq 0 ]] \
   && [[ "$(url_of 2)" == "https://api.openai.com/v1/responses/resp_bg?stream=true&starting_after=0" ]] \
   && [[ "$(url_of 3)" == "https://api.openai.com/v1/responses/resp_bg?stream=true&starting_after=3" ]]; then
    ok "a resumed stream advances its own high-water sequence before a second resume"
else
    bad "a resumed stream advances its own high-water sequence before a second resume" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout") resume=$(url_of 3)"
fi

reset stream-fixture
printf 'data: %s\n\n' '{"type":"response.completed","sequence_number":4,"response":{"id":"resp_bg","status":"completed","output":[]}}' >> "$CURL_STREAM_FIXTURE"
LLM_RESPONSES_BACKGROUND=0 run_bg "foreground" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == 'ab' && "$(calls)" -eq 1 && "$(cancels)" -eq 0 ]]; then
    ok "foreground streams also discard duplicate and out-of-order deltas"
else
    bad "foreground streams also discard duplicate and out-of-order deltas" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout")"
fi

for sequence in '"08"' '0.5' '9007199254740992' '-1' 'null' 'true'; do
    reset stream-fixture
    stream_events '{"type":"response.created","sequence_number":0,"response":{"id":"resp_bg","status":"in_progress","output":[]}}' \
        "{\"type\":\"response.output_text.delta\",\"sequence_number\":$sequence,\"delta\":\"INVALID\"}" \
        '{"type":"response.completed","sequence_number":4,"response":{"id":"resp_bg","status":"completed","output":[]}}'
    LLM_RESPONSES_BACKGROUND=0 run_bg "foreground" >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && ! -s "$WORK/stdout" && "$(calls)" -eq 1 && "$(cancels)" -eq 0 ]] \
       && jq -e '.id == "resp_bg" and .error.code == "outcome_unknown"' "$WORK/response.json" >/dev/null; then
        ok "foreground stream refuses a sequence that is not a nonnegative safe integer number: $sequence"
    else
        bad "foreground stream refuses a sequence that is not a nonnegative safe integer number: $sequence" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout")"
    fi
done

# --- polling ------------------------------------------------------------------
# A buffered background create returns queued; llm polls the response by id
# until it is terminal, then treats the final object like any buffered reply.
reset $'create-queued\npoll-in-progress\npoll-completed'
LLM_RESPONSES_BACKGROUND=1 run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "done" && "$(calls)" -eq 3 ]] \
   && [[ "$(url_of 2)" == "https://api.openai.com/v1/responses/resp_bg" ]] \
   && [[ "$(url_of 3)" == "https://api.openai.com/v1/responses/resp_bg" ]] \
   && ! has_arg 2 "-d" && ! has_arg 3 "-d" \
   && jq -e '.background == true and .stream == false' "$CURL_DIR/payload-1" >/dev/null \
   && jq -e '.status == "completed" and .id == "resp_bg"' "$WORK/response.json" >/dev/null \
   && jq -e '.in_tok == 11' "$WORK/usage.json" >/dev/null; then
    ok "background --no-stream polls the response by id until it completes"
else
    bad "background --no-stream polls the response by id until it completes" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout") u2=$(url_of 2) u3=$(url_of 3) stderr=$(cat "$WORK/stderr")"
fi

# A transient poll failure is retried within LLM_RETRIES; the poll succeeds.
reset $'create-queued\npoll-500\npoll-completed'
LLM_RETRIES=1 LLM_RESPONSES_BACKGROUND=1 run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "done" && "$(calls)" -eq 3 ]]; then
    ok "a transient poll error is retried without recreating the response"
else
    bad "a transient poll error is retried without recreating the response" "rc=$rc calls=$(calls) stderr=$(cat "$WORK/stderr")"
fi

# cancelled is terminal: sidecar, no text, warning, non-zero.
reset $'create-queued\npoll-cancelled'
LLM_RESPONSES_BACKGROUND=1 run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && ! -s "$WORK/stdout" ]] \
   && jq -e '.status == "cancelled"' "$WORK/response.json" >/dev/null \
   && grep -q 'response cancelled' "$WORK/stderr"; then
    ok "a cancelled background response fails with its terminal state"
else
    bad "a cancelled background response fails with its terminal state" "rc=$rc out=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr")"
fi

# --- streaming: resume from the last sequence number -------------------------
reset $'stream-created-drop\nstream-resume-complete'
LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "ab!" && "$(calls)" -eq 2 ]] \
   && [[ "$(url_of 2)" == "https://api.openai.com/v1/responses/resp_bg?stream=true&starting_after=3" ]] \
   && ! has_arg 2 "-d" \
   && jq -e '.background == true and .stream == true' "$CURL_DIR/payload-1" >/dev/null \
   && jq -e '.status == "completed"' "$WORK/response.json" >/dev/null \
   && grep -q 'resuming' "$WORK/stderr"; then
    ok "a dropped background stream resumes after its last sequence number"
else
    bad "a dropped background stream resumes after its last sequence number" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout") u2=$(url_of 2) stderr=$(cat "$WORK/stderr")"
fi

# Text streamed before the drop is not printed again when the resume only
# delivers the terminal event.
reset $'stream-created-drop\nstream-resume-terminal-only'
LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "ab" && "$(calls)" -eq 2 ]]; then
    ok "a resume that brings only the terminal event repeats no text"
else
    bad "a resume that brings only the terminal event repeats no text" "rc=$rc calls=$(calls) out=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr")"
fi

# A lost acknowledgement is not evidence that the create was never accepted.
reset $'stream-empty\nstream-complete'
LLM_RETRIES=2 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(calls)" -eq 1 ]] \
   && jq -e '.error.code == "outcome_unknown"' "$WORK/response.json" >/dev/null; then
    ok "a drop before the response id is known never recreates"
else
    bad "a drop before the response id is known never recreates" "rc=$rc calls=$(calls) stderr=$(cat "$WORK/stderr")"
fi

# Resumes are bounded by LLM_RETRIES; when they run out the job is cancelled.
reset $'stream-created-drop\nstream-created-drop'
LLM_RETRIES=1 LLM_RESPONSES_BACKGROUND=1 run_bg "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(calls)" -eq 3 && "$(cancels)" -eq 1 ]] \
   && [[ "$(cancel_url)" == "https://api.openai.com/v1/responses/resp_bg/cancel" ]] \
   && grep -q 'resumes are used up' "$WORK/stderr"; then
    ok "exhausted resumes cancel the background response"
else
    bad "exhausted resumes cancel the background response" "rc=$rc calls=$(calls) cancels=$(cancels) stderr=$(cat "$WORK/stderr")"
fi

# A cut after the first code block leaves the model generating: cancel it.
reset $'stream-bg-block'
LLM_RESPONSES_BACKGROUND=1 run_bg --stop-after-code-block "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == $'```bash\necho hi\n```' && "$(cancels)" -eq 1 ]]; then
    ok "stop-after-code-block cancels the background response it abandons"
else
    bad "stop-after-code-block cancels the background response it abandons" "rc=$rc cancels=$(cancels) out=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr")"
fi

# --- cancel on signal and on deadline -----------------------------------------
reset $'create-queued\npoll-in-progress'
LLM_API_FORMAT=responses LLM_RESPONSE_FILE="$WORK/response.json" \
LLM_RESPONSES_POLL_INTERVAL=1 LLM_RESPONSES_BACKGROUND=1 \
    "$LLM" --provider openai -m gpt-5.4-mini --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr" &
pid=$!
i=0
while [[ "$(calls)" -lt 2 && "$i" -lt 100 ]]; do sleep 0.1; i=$((i+1)); done
kill -TERM "$pid" 2>/dev/null
wait "$pid"
rc=$?
if [[ "$rc" -ne 0 && "$(cancels)" -eq 1 ]] \
   && [[ "$(cancel_url)" == "https://api.openai.com/v1/responses/resp_bg/cancel" ]] \
   && grep -q 'background response resp_bg confirmed cancelled' "$WORK/stderr"; then
    ok "SIGTERM while polling cancels the background response"
else
    bad "SIGTERM while polling cancels the background response" "rc=$rc calls=$(calls) cancels=$(cancels) stderr=$(cat "$WORK/stderr")"
fi

reset $'create-queued\npoll-in-progress'
LLM_MAX_TIME=1 LLM_RESPONSES_POLL_INTERVAL=1 LLM_RESPONSES_BACKGROUND=1 \
    run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(cancels)" -eq 1 ]] && grep -q 'LLM_MAX_TIME' "$WORK/stderr"; then
    ok "LLM_MAX_TIME bounds the whole wait and cancels the response"
else
    bad "LLM_MAX_TIME bounds the whole wait and cancels the response" "rc=$rc calls=$(calls) cancels=$(cancels) stderr=$(cat "$WORK/stderr")"
fi

# --- opting in --------------------------------------------------------------------
printf '%s' '{"background":true}' > "$WORK/body.json"
reset $'create-queued\npoll-completed'
LLM_RESPONSES_BODY_FILE="$WORK/body.json" run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "done" && "$(calls)" -eq 2 ]] \
   && jq -e '.background == true' "$CURL_DIR/payload-1" >/dev/null; then
    ok "background:true in the body file is accepted and polled"
else
    bad "background:true in the body file is accepted and polled" "rc=$rc calls=$(calls) stderr=$(cat "$WORK/stderr")"
fi

reset $'poll-completed'
LLM_RESPONSES_BACKGROUND=0 LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
    run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(calls)" -eq 1 ]] \
   && jq -e 'has("background") | not' "$CURL_DIR/payload-1" >/dev/null; then
    ok "LLM_RESPONSES_BACKGROUND=0 owns the field over the body file"
else
    bad "LLM_RESPONSES_BACKGROUND=0 owns the field over the body file" "rc=$rc calls=$(calls) payload=$(cat "$CURL_DIR/payload-1" 2>/dev/null)"
fi

reset $'create-queued'
LLM_RESPONSES_BACKGROUND=maybe run_bg --no-stream "bg" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(calls)" -eq 0 ]] && grep -q 'Invalid LLM_RESPONSES_BACKGROUND' "$WORK/stderr"; then
    ok "an invalid LLM_RESPONSES_BACKGROUND fails before any request"
else
    bad "an invalid LLM_RESPONSES_BACKGROUND fails before any request" "rc=$rc calls=$(calls) stderr=$(cat "$WORK/stderr")"
fi

reset $'chat-ok'
LLM_RESPONSES_BACKGROUND=1 LLM_API_FORMAT=chat \
    "$LLM" --provider openai -m gpt-5.4-mini --no-stream "x" >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -eq 0 && "$(cat "$WORK/stdout")" == "ok" ]] \
   && grep -q 'LLM_RESPONSES_BACKGROUND ignored' "$WORK/stderr" \
   && jq -e 'has("background") | not' "$CURL_DIR/payload-1" >/dev/null; then
    ok "chat mode ignores the background flag with a note"
else
    bad "chat mode ignores the background flag with a note" "rc=$rc out=$(cat "$WORK/stdout") stderr=$(cat "$WORK/stderr")"
fi

# Fault boundaries must never turn terminal failure or an ambiguous create
# into another POST, even when retry budget remains.
for mode in create-lost poll-cancelled stream-cancelled; do
    reset "$mode"
    args=(--no-stream)
    [[ "$mode" != stream-* ]] || args=()
    LLM_RETRIES=3 LLM_RESPONSES_BACKGROUND=1 run_bg "${args[@]+"${args[@]}"}" bg >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && "$(calls)" -eq 1 ]]; then ok "$mode fails without recreating"
    else bad "$mode fails without recreating" "rc=$rc calls=$(calls)"; fi
done

for mode in poll-error poll-invalid; do
    reset "$(printf 'create-queued\n%s' "$mode")"
    LLM_RESPONSES_BACKGROUND=1 run_bg --no-stream bg >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    if [[ "$rc" -ne 0 && ! -s "$WORK/stdout" ]]; then ok "$mode cannot become a successful completion"
    else bad "$mode cannot become a successful completion" "rc=$rc"; fi
done

reset $'stream-created-drop\nstream-cancelled'
LLM_RETRIES=3 LLM_RESPONSES_BACKGROUND=1 run_bg bg >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$(calls)" -eq 2 && "$(cancels)" -eq 0 ]] \
    && jq -e '.status == "cancelled"' "$WORK/response.json" >/dev/null; then
    ok "external cancellation during resume is terminal, not another cancel or create"
else bad "external cancellation during resume is terminal, not another cancel or create" "rc=$rc calls=$(calls)"; fi

reset stream-created-drop
CANCEL_FAIL=1 LLM_RETRIES=0 LLM_RESPONSES_BACKGROUND=1 run_bg bg >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'cancellation not confirmed' "$WORK/stderr" \
    && jq -e '.id == "resp_bg" and .error.code == "outcome_unknown" and .cancellation.http_code == "500"' "$WORK/response.json" >/dev/null; then
    ok "failed cancellation preserves recovery handle without claiming success"
else bad "failed cancellation preserves recovery handle without claiming success"; fi

reset $'create-queued\npoll-completed'
start=$SECONDS
LLM_MAX_TIME=1 LLM_RESPONSES_POLL_INTERVAL=30 LLM_RESPONSES_BACKGROUND=1 run_bg --no-stream bg >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$((SECONDS-start))" -lt 5 && "$(calls)" -eq 2 && "$(cancels)" -eq 1 ]]; then
    ok "long poll sleep is clamped; no GET starts after the deadline"
else bad "long poll sleep is clamped; no GET starts after the deadline" "rc=$rc calls=$(calls)"; fi

for mode in create-queued stream-created-drop; do
    reset "$mode"
    args=(--no-stream)
    [[ "$mode" != stream-* ]] || args=()
    # Allow local setup to finish before the fake transfer consumes the
    # original budget. The phase receipt keeps a pre-CREATE refusal visible.
    CURL_DELAY=4 LLM_MAX_TIME=3 LLM_RETRIES=3 LLM_RESPONSES_BACKGROUND=1 \
        run_bg "${args[@]+"${args[@]}"}" bg >"$WORK/stdout" 2>"$WORK/stderr"
    rc=$?
    printf 'slow %s phase receipt: %s\n' "$mode" "$(cat "$CURL_DIR/delay-phases.jsonl" 2>/dev/null)"
    if [[ "$rc" -ne 0 && "$(calls)" -eq 2 && "$(cancels)" -eq 1 ]] \
       && grep -q 'LLM_MAX_TIME' "$WORK/stderr" \
       && jq -e -s --arg mode "$mode" 'length == 2
            and all(.[]; .call == 1 and .mode == $mode)
            and .[0].phase == "delay-entered" and .[1].phase == "delay-released"
            and (.[1].epoch_seconds - .[0].epoch_seconds >= 4)' "$CURL_DIR/delay-phases.jsonl" >/dev/null 2>&1 \
       && jq -es 'length == 1 and (.[0] | type == "object" and .id == "resp_bg"
            and .status == "cancelled" and (.output | type == "array"))' "$WORK/response.json" >/dev/null 2>&1; then
        ok "slow $mode spends the original deadline, not a new poll/resume budget"
    else
        bad "slow $mode spends the original deadline, not a new poll/resume budget" \
            "rc=$rc calls=$(calls) cancels=$(cancels) stderr=$(cat "$WORK/stderr")"
    fi
done

reset stream-created-drop
start=$SECONDS
LLM_MAX_TIME=1 LLM_RETRY_BACKOFF=30 LLM_RETRIES=3 LLM_RESPONSES_BACKGROUND=1 run_bg bg >"$WORK/stdout" 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 && "$((SECONDS-start))" -lt 5 && "$(calls)" -eq 2 && "$(cancels)" -eq 1 ]]; then
    ok "resume backoff is clamped to the original deadline"
else bad "resume backoff is clamped to the original deadline" "rc=$rc calls=$(calls)"; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
