#!/usr/bin/env bash
# test_responses_ws.sh — tools/responses-ws, the Responses WebSocket adapter
#
# Usage: tests/test_responses_ws.sh
#
# A fake WebSocket server written against the same library the adapter uses
# stands in for api.openai.com, so this is hermetic: nothing leaves the loopback
# interface. RESPONSES_WS_URL points the adapter at it. The cases:
#
#   - the response.create payload: model, input passthrough, instructions,
#     previous_response_id, reasoning effort, extra-body store passthrough,
#     the encrypted-reasoning include, and no transport-only fields
#   - streamed text order on stdout, reasoning summary on stderr, through the
#     whole bin/llm adapter path
#   - the terminal sidecar (mode 0600, terminal object) and LLM_USAGE_FILE
#   - an error event naming previous_response_id: non-zero exit with the
#     envelope in the sidecar, matching the pattern shellm falls back on
#   - the broker: two concurrent callers through one unix socket get their own
#     stream_id lanes and both complete, and stop shuts it down
#
# The adapter needs uv (it is a PEP 723 script). Without uv, or without a way
# to prepare its one dependency, the test prints one skip line and exits 0,
# like the Docker-gated tests.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
cleanup_all() {
    [[ -n "${BROKER_PID:-}" ]] && kill "$BROKER_PID" 2>/dev/null
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup_all EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

if ! command -v uv >/dev/null 2>&1; then
    echo "ok   skipped: uv is not installed (tools/responses-ws is a uv PEP 723 script)"
    exit 0
fi

# --- the fake OpenAI WebSocket endpoint --------------------------------------
# Records every response.create it receives and answers with the SSE event
# shapes the Responses API uses. FAKE_MODE picks the answer; FAKE_PAIR makes it
# hold each response until two have arrived, so a broker that serialised its
# callers instead of giving them lanes would stall rather than pass.
cat > "$WORK/fake_server.py" <<'PYEOF'
# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=13"]
# ///
import asyncio
import json
import os
import pathlib
import uuid

import websockets
from websockets.asyncio.server import serve

REQ_DIR = pathlib.Path(os.environ["FAKE_REQ_DIR"])
MODE = os.environ.get("FAKE_MODE", "ok")
PAIR = int(os.environ.get("FAKE_PAIR", "0"))

arrived = 0
both = asyncio.Event()


async def answer(ws, request):
    global arrived
    sid = request.get("stream_id")
    marker = ""
    items = request.get("input") or []
    if items and isinstance(items[-1], dict):
        marker = str(items[-1].get("content") or "")
    rid = "resp_" + uuid.uuid4().hex[:8]
    REQ_DIR.joinpath(rid + ".json").write_text(json.dumps(request))

    if PAIR:
        arrived += 1
        if arrived >= 2:
            both.set()
        try:
            await asyncio.wait_for(both.wait(), timeout=10)
        except asyncio.TimeoutError:
            pass

    def tag(event):
        if sid is not None:
            event["stream_id"] = sid
        return json.dumps(event)

    if MODE == "prev-missing":
        await ws.send(tag({
            "type": "error",
            "error": {
                "type": "invalid_request_error",
                "code": "previous_response_not_found",
                "param": "previous_response_id",
                "message": "Previous response with id 'resp_gone' not found.",
            },
        }))
        return

    await ws.send(tag({"type": "response.reasoning_summary_text.delta", "delta": "weighing "}))
    await ws.send(tag({"type": "response.reasoning_summary_text.delta", "delta": "options"}))
    await ws.send(tag({"type": "response.output_text.delta", "delta": "hello "}))
    await ws.send(tag({"type": "response.output_text.delta", "delta": marker}))
    await ws.send(tag({
        "type": "response.completed",
        "response": {
            "id": rid,
            "object": "response",
            "status": "completed",
            "output": [
                {"id": "rs_1", "type": "reasoning", "summary": [{"type": "summary_text", "text": "weighing options"}], "encrypted_content": "enc"},
                {"id": "msg_1", "type": "message", "role": "assistant", "status": "completed",
                 "content": [{"type": "output_text", "text": "hello " + marker}]},
            ],
            "usage": {
                "input_tokens": 7,
                "output_tokens": 11,
                "output_tokens_details": {"reasoning_tokens": 3},
                "input_tokens_details": {"cached_tokens": 2},
            },
        },
    }))


async def handler(ws):
    tasks = []
    try:
        async for raw in ws:
            request = json.loads(raw)
            if request.get("type") != "response.create":
                continue
            tasks.append(asyncio.create_task(answer(ws, request)))
    except websockets.exceptions.ConnectionClosed:
        pass
    for task in tasks:
        task.cancel()


async def main():
    async with serve(handler, "127.0.0.1", 0) as server:
        port = server.sockets[0].getsockname()[1]
        pathlib.Path(os.environ["FAKE_PORT_FILE"]).write_text(str(port))
        await asyncio.Future()


asyncio.run(main())
PYEOF

# Preparing the dependency is the same work the adapter itself does, so if it
# cannot be done (no network and no cache) the adapter cannot run either and
# there is nothing here to test.
cat > "$WORK/probe.py" <<'PYEOF'
# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=13"]
# ///
import websockets  # noqa: F401
PYEOF
if ! uv run --quiet --script "$WORK/probe.py" >/dev/null 2>&1; then
    echo "ok   skipped: uv cannot prepare the websockets dependency (no network, no cache)"
    exit 0
fi

ADAPTER="$REPO/tools/responses-ws"
PORT_FILE="$WORK/port"
REQ_DIR="$WORK/requests"

start_server() {   # start_server MODE PAIR
    rm -rf "$REQ_DIR" "$PORT_FILE"
    mkdir -p "$REQ_DIR"
    FAKE_REQ_DIR="$REQ_DIR" FAKE_MODE="$1" FAKE_PAIR="${2:-0}" \
        FAKE_PORT_FILE="$PORT_FILE" \
        uv run --quiet --script "$WORK/fake_server.py" >"$WORK/server.log" 2>&1 &
    SERVER_PID=$!
    local waited=0
    while [[ ! -s "$PORT_FILE" && "$waited" -lt 60 ]]; do
        sleep 0.5
        waited=$((waited + 1))
    done
    [[ -s "$PORT_FILE" ]] || return 1
    WS_URL="ws://127.0.0.1:$(cat "$PORT_FILE")/v1/responses"
    return 0
}

stop_server() {
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
}

# Bounded run: nothing in this test may hang a CI job waiting on a socket.
# The child's stdin is named explicitly because a backgrounded command in a
# non-interactive shell is handed /dev/null otherwise, which would silently
# starve an adapter waiting for its input items.
run_limited() {   # run_limited SECONDS COMMAND...   (stdin from $RUN_STDIN)
    local limit="$1"; shift
    "$@" < "${RUN_STDIN:-/dev/null}" &
    local pid=$!
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [[ "$waited" -lt "$limit" ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
    fi
    wait "$pid"
}

export HEADLONG_HOME="$WORK/home"
mkdir -p "$HEADLONG_HOME"
unset ANTHROPIC_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY \
      LLM_API_KEY LLM_API_URL LLM_MODEL LLM_MAX_TOKENS SHELLM_MODEL \
      SHELLM_API_URL RESPONSES_WS_SOCKET
export OPENAI_API_KEY="test-key"
export LLM_RETRIES=0
export LLM_USAGE_LEDGER=/dev/null

# ---------------------------------------------------------------------------
# The whole bin/llm adapter path against the fake endpoint
# ---------------------------------------------------------------------------

if ! start_server ok 0; then
    bad "fake WebSocket server starts" "$(head -5 "$WORK/server.log" 2>/dev/null)"
    printf '\n%d passed, %d failed\n' "$pass" "$fail"
    exit 1
fi
ok "fake WebSocket server starts"

printf '%s' '{"store":false,"metadata":{"run":"t1"}}' > "$WORK/body.json"
run_limited 90 env \
    LLM_PROVIDER=adapter LLM_ADAPTER="$ADAPTER" \
    LLM_API_FORMAT=responses \
    LLM_RESPONSE_FILE="$WORK/response.json" \
    LLM_USAGE_FILE="$WORK/usage.json" \
    LLM_RESPONSES_BODY_FILE="$WORK/body.json" \
    LLM_PREVIOUS_RESPONSE_ID=resp_prev \
    RESPONSES_WS_URL="$WS_URL" \
    "$REPO/bin/llm" -m gpt-5.5 -t 321 -s "be brief" --thinking high "world" \
    >"$WORK/out" 2>"$WORK/err"
rc=$?

REQ=$(ls "$REQ_DIR"/*.json 2>/dev/null | head -1)
if [[ "$rc" -eq 0 && -n "$REQ" ]]; then
    ok "llm drives the adapter to a completed response"
else
    bad "llm drives the adapter to a completed response" "rc=$rc: $(head -3 "$WORK/err")"
fi

if [[ -n "$REQ" ]] && jq -e '
        .type == "response.create"
        and .model == "gpt-5.5"
        and .max_output_tokens == 321
        and .instructions == "be brief"
        and .previous_response_id == "resp_prev"
        and .reasoning.effort == "high"
        and .reasoning.summary == "auto"
        and .store == false
        and .metadata.run == "t1"
        and (.include | index("reasoning.encrypted_content")) != null
        and (has("stream") | not)
        and (has("background") | not)' "$REQ" >/dev/null 2>&1; then
    ok "the response.create payload carries the create body without transport fields"
else
    bad "the response.create payload carries the create body without transport fields" "$(jq -c . "$REQ" 2>/dev/null | head -c 300)"
fi

if [[ -n "$REQ" ]] && jq -e '.input | type == "array" and length == 1
        and .[0].role == "user" and (.[0].content | contains("world"))' "$REQ" >/dev/null 2>&1; then
    ok "typed input items pass through unreshaped"
else
    bad "typed input items pass through unreshaped" "$(jq -c '.input' "$REQ" 2>/dev/null)"
fi

if [[ "$(cat "$WORK/out")" == "hello world" ]]; then
    ok "streamed text arrives on stdout in order"
else
    bad "streamed text arrives on stdout in order" "$(cat "$WORK/out")"
fi

if grep -q 'weighing options' "$WORK/err"; then
    ok "reasoning summary deltas arrive on stderr"
else
    bad "reasoning summary deltas arrive on stderr" "$(head -3 "$WORK/err")"
fi

if jq -e '.status == "completed" and (.id | startswith("resp_")) and (.output | length) == 2' \
        "$WORK/response.json" >/dev/null 2>&1; then
    ok "the terminal Response object lands in the sidecar"
else
    bad "the terminal Response object lands in the sidecar" "$(head -c 200 "$WORK/response.json" 2>/dev/null)"
fi

mode=$(stat -c %a "$WORK/response.json" 2>/dev/null || stat -f %Lp "$WORK/response.json" 2>/dev/null)
if [[ "$mode" == "600" ]]; then
    ok "the sidecar is mode 0600"
else
    bad "the sidecar is mode 0600" "mode=$mode"
fi

if jq -e '.in_tok == 7 and .out_tok == 11 and .think_tok == 3 and .cache_tok == 2' \
        "$WORK/usage.json" >/dev/null 2>&1; then
    ok "usage is recorded in LLM_USAGE_FILE"
else
    bad "usage is recorded in LLM_USAGE_FILE" "$(cat "$WORK/usage.json" 2>/dev/null)"
fi

stop_server

# ---------------------------------------------------------------------------
# A rejected previous_response_id fails the call with the envelope in the
# sidecar, in the shape shellm's replay fallback looks for
# ---------------------------------------------------------------------------

if start_server prev-missing 0; then
    rm -f "$WORK/response.json"
    printf '%s' '[{"role":"user","content":"world"}]' > "$WORK/input.json"
    RUN_STDIN="$WORK/input.json"
    run_limited 90 env \
        LLM_RESPONSE_FILE="$WORK/response.json" \
        LLM_PREVIOUS_RESPONSE_ID=resp_gone \
        RESPONSES_WS_URL="$WS_URL" \
        "$ADAPTER" --model gpt-5.5 --max-tokens 64 --api-format responses \
        >"$WORK/out" 2>"$WORK/err"
    rc=$?
    RUN_STDIN=""
    if [[ "$rc" -ne 0 && ! -s "$WORK/out" ]]; then
        ok "an error event fails the call with no text on stdout"
    else
        bad "an error event fails the call with no text on stdout" "rc=$rc out=$(cat "$WORK/out")"
    fi
    # The same jq test bin/shellm uses to decide on the replay fallback.
    if jq -e '[.error.param?,.error.code?,.error.message?,.param?,.code?,.message?,.detail?]
              | map(select(. != null) | tostring | ascii_downcase) | join(" ")
              | test("previous[ _]response[ _]id|previous response")' \
            "$WORK/response.json" >/dev/null 2>&1; then
        ok "the error envelope in the sidecar triggers shellm's replay fallback"
    else
        bad "the error envelope in the sidecar triggers shellm's replay fallback" "$(cat "$WORK/response.json" 2>/dev/null)"
    fi
    stop_server
else
    bad "fake WebSocket server starts (prev-missing)" "$(head -5 "$WORK/server.log" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# The broker: one connection, two concurrent callers, two lanes
# ---------------------------------------------------------------------------

if start_server ok 1; then
    SOCK="$WORK/ws.sock"
    RESPONSES_WS_URL="$WS_URL" "$ADAPTER" serve --socket "$SOCK" --idle 1 \
        >"$WORK/broker.log" 2>&1 &
    BROKER_PID=$!
    waited=0
    while [[ ! -S "$SOCK" && "$waited" -lt 60 ]]; do
        sleep 0.5
        waited=$((waited + 1))
    done

    if [[ -S "$SOCK" ]]; then
        ok "the broker listens on its unix socket"
    else
        bad "the broker listens on its unix socket" "$(head -5 "$WORK/broker.log")"
    fi

    call_through_broker() {   # call_through_broker MARKER OUTFILE
        RESPONSES_WS_SOCKET="$SOCK" LLM_RESPONSE_FILE="$WORK/resp-$1.json" \
            "$ADAPTER" --model gpt-5.5 --max-tokens 64 --api-format responses \
            >"$2" 2>>"$WORK/broker-callers.err" <<EOF
[{"role":"user","content":"$1"}]
EOF
    }

    call_through_broker alpha "$WORK/out-alpha" &
    p1=$!
    call_through_broker beta "$WORK/out-beta" &
    p2=$!
    waited=0
    while { kill -0 "$p1" 2>/dev/null || kill -0 "$p2" 2>/dev/null; } && [[ "$waited" -lt 90 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    kill -9 "$p1" "$p2" 2>/dev/null
    wait "$p1" 2>/dev/null; rc1=$?
    wait "$p2" 2>/dev/null; rc2=$?

    if [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]; then
        ok "two concurrent callers through one broker both complete"
    else
        bad "two concurrent callers through one broker both complete" "rc=$rc1/$rc2: $(tail -3 "$WORK/broker-callers.err" 2>/dev/null)"
    fi
    if [[ "$(cat "$WORK/out-alpha" 2>/dev/null)" == "hello alpha" \
       && "$(cat "$WORK/out-beta" 2>/dev/null)" == "hello beta" ]]; then
        ok "each caller gets its own answer"
    else
        bad "each caller gets its own answer" "alpha=$(cat "$WORK/out-alpha" 2>/dev/null) beta=$(cat "$WORK/out-beta" 2>/dev/null)"
    fi
    lanes=$(cat "$REQ_DIR"/*.json 2>/dev/null | jq -r '.stream_id' | sort -u | grep -c .)
    if [[ "$lanes" -eq 2 ]]; then
        ok "the two calls ride distinct stream_id lanes"
    else
        bad "the two calls ride distinct stream_id lanes" "distinct lanes=$lanes"
    fi

    run_limited 30 "$ADAPTER" stop --socket "$SOCK" >/dev/null 2>&1
    waited=0
    while kill -0 "$BROKER_PID" 2>/dev/null && [[ "$waited" -lt 30 ]]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$BROKER_PID" 2>/dev/null; then
        bad "stop shuts the broker down" "still running after ${waited}s"
        kill -9 "$BROKER_PID" 2>/dev/null
    else
        ok "stop shuts the broker down"
    fi
    BROKER_PID=""
    stop_server
else
    bad "fake WebSocket server starts (broker)" "$(head -5 "$WORK/server.log" 2>/dev/null)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
