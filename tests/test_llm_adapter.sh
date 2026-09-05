#!/usr/bin/env bash
# test_llm_adapter.sh — the adapter seam (LLM_PROVIDER=adapter + LLM_ADAPTER)
#
# Usage: tests/test_llm_adapter.sh
#
# A stub adapter records its argv, its stdin, and the system-prompt file it
# is handed, then answers on stdout — so this checks the invoker side of the
# contract in design/providers.md without any real provider. The cases:
#
#   - the adapter runs and its stdout is llm's stdout
#   - --model and --max-tokens are always passed; unknown names get the
#     16384 fallback cap and -t overrides it
#   - the messages JSON arrives on stdin
#   - -s reaches the adapter via --system-prompt-file
#   - --no-stream, --effort, and --thinking LEVEL are forwarded
#   - LLM_USAGE_FILE reaches the adapter and its usage lands in the ledger
#   - LLM_API_FORMAT=responses is allowed for the adapter provider and adds
#     --api-format responses to the argv, with the Responses environment
#     (LLM_RESPONSE_FILE, LLM_PREVIOUS_RESPONSE_ID, LLM_RESPONSES_BODY_FILE)
#     visible to the adapter; chat mode passes no --api-format at all
#   - the system-prompt tempfile is mode 0600 (private prompt in /tmp)
#   - LLM_MAX_TIME is a hard deadline: TERM, 5s grace, then KILL — and a
#     deadline expiry fails the call even if the adapter exits 0 on TERM
#   - missing LLM_ADAPTER dies loudly; a non-executable path dies loudly
#   - a nonzero adapter exit fails the call with the adapter's exit code
#     reported, and the health marker records the error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- stub adapter ------------------------------------------------------------
# Records argv to $ADAPTER_ARGS (one per line) and stdin to $ADAPTER_STDIN.
# Copies the --system-prompt-file target to $ADAPTER_SYS (the real file is a
# tempfile llm removes). Writes usage JSON when ADAPTER_USAGE is set. Answers
# "adapter says ok", or exits $ADAPTER_RC.
cat > "$WORK/adapter" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$ADAPTER_ARGS"
cat > "$ADAPTER_STDIN"
prev=""
for a in "$@"; do
    if [[ "$prev" == "--system-prompt-file" ]]; then
        cat "$a" > "$ADAPTER_SYS"
        { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } > "$ADAPTER_SYS_MODE"
    fi
    prev="$a"
done
if [[ -n "${ADAPTER_ENV:-}" ]]; then
    {
        printf 'LLM_API_FORMAT=%s\n' "${LLM_API_FORMAT:-}"
        printf 'LLM_RESPONSE_FILE=%s\n' "${LLM_RESPONSE_FILE:-}"
        printf 'LLM_PREVIOUS_RESPONSE_ID=%s\n' "${LLM_PREVIOUS_RESPONSE_ID:-}"
        printf 'LLM_RESPONSES_BODY_FILE=%s\n' "${LLM_RESPONSES_BODY_FILE:-}"
    } > "$ADAPTER_ENV"
fi
if [[ -n "${ADAPTER_USAGE:-}" && -n "${LLM_USAGE_FILE:-}" ]]; then
    printf '%s' "$ADAPTER_USAGE" > "$LLM_USAGE_FILE"
fi
if [[ "${ADAPTER_RC:-0}" -ne 0 ]]; then
    echo "stub adapter failing on purpose" >&2
    exit "$ADAPTER_RC"
fi
printf 'adapter says ok'
EOF
chmod +x "$WORK/adapter"

export HEADLONG_HOME="$WORK/home"   # bin/llm writes run/llm_health.json here
mkdir -p "$HEADLONG_HOME"
export ADAPTER_ARGS="$WORK/adapter_args"
export ADAPTER_STDIN="$WORK/adapter_stdin"
export ADAPTER_SYS="$WORK/adapter_sys"
export ADAPTER_SYS_MODE="$WORK/adapter_sys_mode"
export ADAPTER_ENV="$WORK/adapter_env"
export LLM_RETRIES=0
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
      OPENCODE_API_KEY LLM_API_KEY LLM_PROVIDER LLM_API_URL LLM_MODEL \
      LLM_MAX_TOKENS SHELLM_MODEL SHELLM_API_URL LLM_ADAPTER \
      ADAPTER_USAGE ADAPTER_RC LLM_USAGE_FILE LLM_USAGE_LEDGER \
      LLM_API_FORMAT LLM_RESPONSE_FILE LLM_PREVIOUS_RESPONSE_ID \
      LLM_RESPONSES_BODY_FILE
cd "$WORK" || exit 1

LLM="$REPO/bin/llm"

reset() { : > "$ADAPTER_ARGS"; : > "$ADAPTER_STDIN"; : > "$ADAPTER_SYS"; : > "$ADAPTER_ENV"; }

has_arg_pair() {  # has_arg_pair FLAG VALUE — argv is recorded one per line
    grep -A1 -x -- "$1" "$ADAPTER_ARGS" | tail -1 | grep -qx -- "$2"
}

# ---------------------------------------------------------------------------
# The adapter runs, stdout passes through, flags carry model and cap
# ---------------------------------------------------------------------------

reset
out=$(LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
      "$LLM" -m qwen3:8b "say ok" 2>"$WORK/stderr")
rc=$?
if [[ "$rc" -eq 0 && "$out" == "adapter says ok" ]]; then
    ok "adapter runs and its stdout is llm's stdout"
else
    bad "adapter runs and its stdout is llm's stdout" "rc=$rc: $(head -1 "$WORK/stderr")"
fi
if has_arg_pair "--model" "qwen3:8b"; then
    ok "--model is passed"
else
    bad "--model is passed" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi
if has_arg_pair "--max-tokens" "16384"; then
    ok "unknown model gets the 16384 fallback cap"
else
    bad "unknown model gets the 16384 fallback cap" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi
if jq -e '.[0].role == "user" and (.[0].content | contains("say ok"))' "$ADAPTER_STDIN" >/dev/null 2>&1; then
    ok "messages JSON arrives on stdin"
else
    bad "messages JSON arrives on stdin" "$(head -c 120 "$ADAPTER_STDIN")"
fi

# ---------------------------------------------------------------------------
# -t override, system prompt, --no-stream, --effort, --thinking LEVEL
# ---------------------------------------------------------------------------

reset
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
    "$LLM" -t 512 -m qwen3:8b -s "be brief" --no-stream \
    --effort low --thinking high "say ok" >/dev/null 2>"$WORK/stderr"
if has_arg_pair "--max-tokens" "512"; then
    ok "-t overrides the cap"
else
    bad "-t overrides the cap" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi
if [[ "$(cat "$ADAPTER_SYS")" == "be brief" ]]; then
    ok "-s reaches the adapter via --system-prompt-file"
else
    bad "-s reaches the adapter via --system-prompt-file" "$(cat "$ADAPTER_SYS")"
fi
if [[ "$(cat "$ADAPTER_SYS_MODE")" == "600" ]]; then
    ok "system prompt tempfile is mode 0600"
else
    bad "system prompt tempfile is mode 0600" "mode=$(cat "$ADAPTER_SYS_MODE")"
fi
if grep -qx -- "--no-stream" "$ADAPTER_ARGS"; then
    ok "--no-stream is forwarded"
else
    bad "--no-stream is forwarded"
fi
if has_arg_pair "--effort" "low"; then
    ok "--effort is forwarded"
else
    bad "--effort is forwarded" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi
if has_arg_pair "--thinking" "high"; then
    ok "--thinking LEVEL is forwarded"
else
    bad "--thinking LEVEL is forwarded" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi

# ---------------------------------------------------------------------------
# Usage lands in the ledger
# ---------------------------------------------------------------------------

reset
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
    ADAPTER_USAGE='{"in_tok":11,"out_tok":22}' \
    LLM_USAGE_LEDGER="$WORK/ledger.jsonl" \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
if grep -q '"in_tok":11' "$WORK/ledger.jsonl" 2>/dev/null \
   && grep -q '"provider":"adapter"' "$WORK/ledger.jsonl"; then
    ok "adapter usage lands in the ledger"
else
    bad "adapter usage lands in the ledger" "$(head -1 "$WORK/ledger.jsonl" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# Responses format reaches the adapter (tools/responses-ws needs this)
# ---------------------------------------------------------------------------

reset
printf '%s' '{"store":false}' > "$WORK/body.json"
out=$(LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
      LLM_API_FORMAT=responses \
      LLM_RESPONSE_FILE="$WORK/resp.json" \
      LLM_PREVIOUS_RESPONSE_ID=resp_prev \
      LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
      "$LLM" -m gpt-5.5 "say ok" 2>"$WORK/stderr")
rc=$?
if [[ "$rc" -eq 0 && "$out" == "adapter says ok" ]]; then
    ok "the adapter provider is allowed under LLM_API_FORMAT=responses"
else
    bad "the adapter provider is allowed under LLM_API_FORMAT=responses" "rc=$rc: $(head -1 "$WORK/stderr")"
fi
if has_arg_pair "--api-format" "responses"; then
    ok "--api-format responses is forwarded"
else
    bad "--api-format responses is forwarded" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
fi
if grep -qx "LLM_RESPONSE_FILE=$WORK/resp.json" "$ADAPTER_ENV" \
   && grep -qx 'LLM_PREVIOUS_RESPONSE_ID=resp_prev' "$ADAPTER_ENV" \
   && grep -qx "LLM_RESPONSES_BODY_FILE=$WORK/body.json" "$ADAPTER_ENV"; then
    ok "the Responses environment reaches the adapter"
else
    bad "the Responses environment reaches the adapter" "$(tr '\n' ' ' < "$ADAPTER_ENV")"
fi
if jq -e '.[0].role == "user"' "$ADAPTER_STDIN" >/dev/null 2>&1; then
    ok "typed Responses input arrives on stdin"
else
    bad "typed Responses input arrives on stdin" "$(head -c 120 "$ADAPTER_STDIN")"
fi

reset
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
if grep -qx -- "--api-format" "$ADAPTER_ARGS"; then
    bad "chat mode passes no --api-format" "$(tr '\n' ' ' < "$ADAPTER_ARGS")"
else
    ok "chat mode passes no --api-format"
fi

# ---------------------------------------------------------------------------
# Missing and non-executable adapters die loudly
# ---------------------------------------------------------------------------

reset
LLM_PROVIDER=adapter "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'LLM_ADAPTER is not set' "$WORK/stderr"; then
    ok "missing LLM_ADAPTER dies loudly"
else
    bad "missing LLM_ADAPTER dies loudly" "rc=$rc"
fi

reset
: > "$WORK/not-exec"
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/not-exec" \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'not executable' "$WORK/stderr"; then
    ok "non-executable LLM_ADAPTER dies loudly"
else
    bad "non-executable LLM_ADAPTER dies loudly" "rc=$rc"
fi

# ---------------------------------------------------------------------------
# The LLM_MAX_TIME deadline is hard
# ---------------------------------------------------------------------------

# An adapter that traps TERM and exits 0 must still be reported as a
# deadline failure — a post-deadline exit 0 recording ok would make the
# health marker lie about a call that produced no answer.
cat > "$WORK/adapter-trap-term" <<'EOF'
#!/usr/bin/env bash
trap 'kill "$spid" 2>/dev/null; exit 0' TERM
sleep 30 & spid=$!
wait "$spid"
EOF
chmod +x "$WORK/adapter-trap-term"

reset
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter-trap-term" LLM_MAX_TIME=1 \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'LLM_MAX_TIME deadline' "$WORK/stderr"; then
    ok "deadline expiry fails the call even when the adapter exits 0 on TERM"
else
    bad "deadline expiry fails the call even when the adapter exits 0 on TERM" "rc=$rc: $(head -1 "$WORK/stderr")"
fi
if jq -e '.ok == false' "$HEADLONG_HOME/run/llm_health.json" >/dev/null 2>&1; then
    ok "deadline failure is recorded in the health marker"
else
    bad "deadline failure is recorded in the health marker" "$(cat "$HEADLONG_HOME/run/llm_health.json" 2>/dev/null)"
fi

# An adapter that ignores TERM entirely is KILLed after the grace period.
cat > "$WORK/adapter-ignore-term" <<'EOF'
#!/usr/bin/env bash
trap '' TERM
sleep 30
EOF
chmod +x "$WORK/adapter-ignore-term"

reset
_t0=$(date +%s)
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter-ignore-term" LLM_MAX_TIME=1 \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
if [[ "$rc" -ne 0 && "$_elapsed" -lt 15 ]] && grep -q 'LLM_MAX_TIME deadline' "$WORK/stderr"; then
    ok "a TERM-ignoring adapter is KILLed within the grace period"
else
    bad "a TERM-ignoring adapter is KILLed within the grace period" "rc=$rc elapsed=${_elapsed}s: $(head -1 "$WORK/stderr")"
fi

# The deadline kills the adapter's whole process group even when the group
# leader exits cleanly on TERM while a child ignores it. Stopping the watcher
# when the leader exits would let that child hold stdout open and block a
# $(...) caller (thinkers use command substitution) past the deadline.
cat > "$WORK/adapter-with-child" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
bash -c 'trap "" TERM; sleep 30' &
wait
EOF
chmod +x "$WORK/adapter-with-child"

reset
_t0=$(date +%s)
out=$(LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter-with-child" LLM_MAX_TIME=1 \
      "$LLM" -m qwen3:8b "say ok" 2>"$WORK/stderr")
rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
if [[ "$rc" -ne 0 && "$_elapsed" -lt 15 ]]; then
    ok "the adapter's children die with it (stdout not held past the deadline)"
else
    bad "the adapter's children die with it (stdout not held past the deadline)" "rc=$rc elapsed=${_elapsed}s"
fi

# A fast adapter pays no watcher tick: two calls, well under a second each.
reset
_t0=$(date +%s)
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>&1
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>&1
_elapsed=$(( $(date +%s) - _t0 ))
if [[ "$_elapsed" -lt 2 ]]; then
    ok "successful calls do not wait out the watcher tick"
else
    bad "successful calls do not wait out the watcher tick" "2 calls took ${_elapsed}s"
fi

# ---------------------------------------------------------------------------
# A failing adapter fails the call and marks health
# ---------------------------------------------------------------------------

reset
LLM_PROVIDER=adapter LLM_ADAPTER="$WORK/adapter" ADAPTER_RC=3 \
    "$LLM" -m qwen3:8b "say ok" >/dev/null 2>"$WORK/stderr"
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'adapter exited 3' "$WORK/stderr"; then
    ok "nonzero adapter exit fails the call with the code reported"
else
    bad "nonzero adapter exit fails the call with the code reported" "rc=$rc: $(head -1 "$WORK/stderr")"
fi
if jq -e '.ok == false' "$HEADLONG_HOME/run/llm_health.json" >/dev/null 2>&1; then
    ok "adapter failure is recorded in the health marker"
else
    bad "adapter failure is recorded in the health marker" "$(cat "$HEADLONG_HOME/run/llm_health.json" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
