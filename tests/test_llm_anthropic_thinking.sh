#!/usr/bin/env bash
# test_llm_anthropic_thinking.sh — Anthropic thinking/effort payload shape
#
# Usage: tests/test_llm_anthropic_thinking.sh
#
# Regression test for two bugs found live against the real Anthropic API on
# claude-sonnet-4-5 (its flagship model):
#
#   - thinking:{type:"adaptive"} is not a real Anthropic API value — the API
#     rejects it outright ("adaptive thinking is not supported on this
#     model"). The real shape is type:"enabled" plus a required numeric
#     budget_tokens.
#   - output_config:{effort:...} is sent unconditionally whenever --effort is
#     given, with no model-capability guard (unlike thinking) — the API
#     rejects it too ("This model does not support the effort parameter").
#     shellm always passes --effort alongside --thinking, so every shellm
#     call to a real Claude model failed on this second bug even once the
#     first was fixed.
#
# curl is stubbed: it captures the payload file bin/llm builds (passed as
# `-d @file`, never argv — see "keep API keys out of curl arguments") and
# answers with a minimal valid SSE stream, so this checks the exact JSON
# bin/llm sends without touching the network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
    if [[ "$prev" == "-d" && "$a" == @* ]]; then
        cp "${a#@}" "$LAST_PAYLOAD"
    fi
    prev="$a"
done
printf 'data: %s\n\n' '{"type":"message_start","message":{"usage":{"input_tokens":5}}}'
printf 'data: %s\n\n' '{"type":"content_block_start","content_block":{"type":"text"}}'
printf 'data: %s\n\n' '{"type":"content_block_delta","delta":{"text":"ok"}}'
printf 'data: %s\n\n' '{"type":"content_block_stop"}'
printf 'data: %s\n\n' '{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":2}}'
printf 'data: [DONE]\n\n'
EOF
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

export ANTHROPIC_API_KEY="test-key"
export HEADLONG_HOME="$WORK/home"
mkdir -p "$HEADLONG_HOME"
export LLM_RETRIES=0
export LAST_PAYLOAD="$WORK/last_payload.json"
unset LLM_PROVIDER LLM_API_URL LLM_MODEL LLM_ASSUME_THINKING

LLM="$REPO/bin/llm"

# ---------------------------------------------------------------------------
# --thinking sends type:"enabled" with a budget under max_tokens, not "adaptive"
# ---------------------------------------------------------------------------

: > "$LAST_PAYLOAD"
out=$(printf 'hi' | "$LLM" -m claude-sonnet-4-5 -t 4000 --thinking 2>"$WORK/stderr")
rc=$?
if [[ "$rc" -eq 0 && "$out" == *ok* ]]; then
    ok "--thinking call succeeds"
else
    bad "--thinking call succeeds" "rc=$rc $(head -1 "$WORK/stderr")"
fi

thinking_type=$(jq -r '.thinking.type // "MISSING"' "$LAST_PAYLOAD")
if [[ "$thinking_type" == "enabled" ]]; then
    ok "thinking.type is \"enabled\", not \"adaptive\""
else
    bad "thinking.type is \"enabled\", not \"adaptive\"" "got: $thinking_type"
fi

budget=$(jq -r '.thinking.budget_tokens // "MISSING"' "$LAST_PAYLOAD")
if [[ "$budget" == "2000" ]]; then
    ok "budget_tokens is half of max_tokens (4000/2)"
else
    bad "budget_tokens is half of max_tokens (4000/2)" "got: $budget"
fi
if [[ "$budget" =~ ^[0-9]+$ ]] && (( budget < 4000 )); then
    ok "budget_tokens stays under max_tokens"
else
    bad "budget_tokens stays under max_tokens" "budget=$budget max_tokens=4000"
fi

# A tiny max_tokens still floors at the API's 1024 minimum.
: > "$LAST_PAYLOAD"
printf 'hi' | "$LLM" -m claude-sonnet-4-5 -t 100 --thinking >/dev/null 2>"$WORK/stderr"
floor_budget=$(jq -r '.thinking.budget_tokens // "MISSING"' "$LAST_PAYLOAD")
if [[ "$floor_budget" == "1024" ]]; then
    ok "budget_tokens floors at 1024 for a small max_tokens"
else
    bad "budget_tokens floors at 1024 for a small max_tokens" "got: $floor_budget"
fi

# ---------------------------------------------------------------------------
# --effort is always ignored for Anthropic (no output_config field sent)
# ---------------------------------------------------------------------------

: > "$LAST_PAYLOAD"
printf 'hi' | "$LLM" -m claude-sonnet-4-5 -t 4000 --thinking --effort high \
    >/dev/null 2>"$WORK/stderr"
has_output_config=$(jq -r 'has("output_config")' "$LAST_PAYLOAD")
if [[ "$has_output_config" == "false" ]]; then
    ok "--effort does not add output_config to the payload"
else
    bad "--effort does not add output_config to the payload" "payload had output_config"
fi
if grep -q -- "--effort ignored" "$WORK/stderr"; then
    ok "--effort being dropped is reported on stderr"
else
    bad "--effort being dropped is reported on stderr" "$(cat "$WORK/stderr")"
fi

# thinking itself must still be sent even when effort is dropped alongside it
# (this is the exact combination shellm always sends).
still_has_thinking=$(jq -r 'has("thinking")' "$LAST_PAYLOAD")
if [[ "$still_has_thinking" == "true" ]]; then
    ok "thinking still sent when --effort is dropped alongside it"
else
    bad "thinking still sent when --effort is dropped alongside it"
fi

# ---------------------------------------------------------------------------
# LLM_ASSUME_THINKING=1 is the escape hatch for both guards
# ---------------------------------------------------------------------------

: > "$LAST_PAYLOAD"
printf 'hi' | LLM_ASSUME_THINKING=1 "$LLM" \
    -m claude-sonnet-4-5 -t 4000 --effort high >/dev/null 2>"$WORK/stderr"
effort_val=$(jq -r '.output_config.effort // "MISSING"' "$LAST_PAYLOAD")
if [[ "$effort_val" == "high" ]]; then
    ok "LLM_ASSUME_THINKING=1 forces output_config.effort through"
else
    bad "LLM_ASSUME_THINKING=1 forces output_config.effort through" "got: $effort_val"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
