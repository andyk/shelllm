#!/usr/bin/env bash
# test_shellm_ws_transport.sh — SHELLM_API_TRANSPORT=websocket wiring
#
# Usage: tests/test_shellm_ws_transport.sh
#
# The broker and the adapter are both stubbed, so this pins shellm's side of
# the contract without uv, Python, or a socket: which transports are legal,
# that the broker is started and stopped around the run, and that shellm's own
# llm calls are pointed at tools/responses-ws through the run's socket. The
# adapter itself is covered by tests/test_responses_ws.sh.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
# shellm resolves the tool through realpath, and on macOS /var is a symlink.
WORK_REAL=$(cd "$WORK" && pwd -P)

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/home" "$WORK/wd" "$WORK/stub"
cp -R "$REPO/bin" "$WORK/toolbin"
mkdir -p "$WORK/tools"

# Stub broker. "serve" creates the socket path and waits; "stop" removes it.
# Both record their argv so the test can pin the socket shellm chose.
cat > "$WORK/tools/responses-ws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WS_STUB_DIR/calls"
sock=""
prev=""
for arg in "$@"; do
    [[ "$prev" == "--socket" ]] && sock="$arg"
    prev="$arg"
done
case "${1:-}" in
    serve)
        printf '%s' "$sock" > "$WS_STUB_DIR/socket"
        : > "$sock"
        trap 'rm -f "$sock"; exit 0' TERM INT
        while [[ -e "$sock" ]]; do sleep 1; done
        ;;
    stop)
        printf 'stopped\n' >> "$WS_STUB_DIR/calls"
        rm -f "$sock"
        ;;
esac
exit 0
STUB
chmod +x "$WORK/tools/responses-ws"

# Stub llm. Records the adapter environment shellm exported, then answers with
# a final block so the run ends after one iteration.
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
main_loop=0
for arg in "$@"; do
    [[ "$arg" == --thinking ]] && main_loop=1
done
if [[ "$main_loop" -ne 1 ]]; then
    printf '{}\n'
    exit 0
fi
{
    printf 'LLM_PROVIDER=%s\n' "${LLM_PROVIDER:-}"
    printf 'LLM_ADAPTER=%s\n' "${LLM_ADAPTER:-}"
    printf 'RESPONSES_WS_SOCKET=%s\n' "${RESPONSES_WS_SOCKET:-}"
    printf 'LLM_API_FORMAT=%s\n' "${LLM_API_FORMAT:-}"
} > "$WS_STUB_DIR/llm-env"
if [[ -n "${LLM_RESPONSE_FILE:-}" ]]; then
    ( umask 077; jq -nc '{
        id: "resp_1", object: "response", status: "completed",
        output: [{id:"msg_1", type:"message", role:"assistant", status:"completed",
                  content:[{type:"output_text", text:"done"}]}]
    }' > "$LLM_RESPONSE_FILE" )
fi
printf '%s\n' '```bash' 'FINAL=done' '```'
STUB
chmod +x "$WORK/toolbin/llm"

export PATH="$WORK/toolbin:$PATH"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export OPENAI_API_KEY="test-key"
export SHELLM_MODEL="gpt-5-test"
export SHELLM_ENV=local
export SHELLM_NO_BANNER=1
export WS_STUB_DIR="$WORK/stub"

run_shellm() {   # run_shellm FORMAT TRANSPORT
    rm -rf "$WS_STUB_DIR" "$HEADLONG_HOME" "$WORK/wd"
    mkdir -p "$WS_STUB_DIR" "$WORK/wd"
    SHELLM_API_FORMAT="$1" SHELLM_API_TRANSPORT="$2" \
        "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 2 "do the task" \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# ---------------------------------------------------------------------------
# The transport is only meaningful with the Responses protocol
# ---------------------------------------------------------------------------

run_shellm chat websocket
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'SHELLM_API_TRANSPORT=websocket' "$WORK/err"; then
    ok "websocket transport without Responses dies with a clear message"
else
    bad "websocket transport without Responses dies with a clear message" "rc=$rc: $(head -2 "$WORK/err")"
fi

run_shellm responses bogus
rc=$?
if [[ "$rc" -ne 0 ]] && grep -q 'SHELLM_API_TRANSPORT' "$WORK/err"; then
    ok "an unknown transport dies with a clear message"
else
    bad "an unknown transport dies with a clear message" "rc=$rc: $(head -2 "$WORK/err")"
fi

# ---------------------------------------------------------------------------
# The broker runs for the length of the run and llm is pointed at it
# ---------------------------------------------------------------------------

run_shellm responses websocket
rc=$?
if [[ "$rc" -eq 0 ]]; then
    ok "a run completes on the websocket transport"
else
    bad "a run completes on the websocket transport" "rc=$rc: $(tail -3 "$WORK/err")"
fi

sock=$(cat "$WS_STUB_DIR/socket" 2>/dev/null)
if [[ -n "$sock" ]] && grep -q "^serve --socket $sock" "$WS_STUB_DIR/calls" 2>/dev/null; then
    ok "shellm starts the broker on a socket of its own"
else
    bad "shellm starts the broker on a socket of its own" "$(cat "$WS_STUB_DIR/calls" 2>/dev/null)"
fi

if [[ "$sock" == /*/shellm-run.*/* ]]; then
    ok "the socket lives in the run's private rundir"
else
    bad "the socket lives in the run's private rundir" "socket=$sock"
fi

if grep -qx "LLM_PROVIDER=adapter" "$WS_STUB_DIR/llm-env" 2>/dev/null \
   && grep -qx "LLM_ADAPTER=$WORK_REAL/tools/responses-ws" "$WS_STUB_DIR/llm-env" \
   && grep -qx "RESPONSES_WS_SOCKET=$sock" "$WS_STUB_DIR/llm-env" \
   && grep -qx "LLM_API_FORMAT=responses" "$WS_STUB_DIR/llm-env"; then
    ok "shellm's llm calls go through the adapter and the run's socket"
else
    bad "shellm's llm calls go through the adapter and the run's socket" "$(tr '\n' ' ' < "$WS_STUB_DIR/llm-env" 2>/dev/null)"
fi

if grep -q "^stop --socket $sock" "$WS_STUB_DIR/calls" 2>/dev/null; then
    ok "cleanup stops the broker"
else
    bad "cleanup stops the broker" "$(cat "$WS_STUB_DIR/calls" 2>/dev/null)"
fi

if [[ -n "$sock" && ! -e "$sock" ]]; then
    ok "the socket is gone when the run is"
else
    bad "the socket is gone when the run is" "socket=$sock"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
