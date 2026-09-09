#!/usr/bin/env bash
# tests/test_responder_partial_reply.sh -- responder exposes active stdout.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ -- $2}"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/shim" "$WORK/id/run" "$WORK/id/memories" "$WORK/id/skills" \
    "$WORK/id/kernel" "$WORK/traj/aaaaaaaa-root"

TRAJ_FILE="$WORK/traj/aaaaaaaa-root/trajectory.jsonl"
STEP_FILE="$WORK/step.json"
READY_FILE="$WORK/llm-ready"
REPLY_FILE="$WORK/chat-reply"
PARTIAL_DIR="$WORK/id/run/responder-partials/trig-1"
PARTIAL_FILE="$PARTIAL_DIR/content.txt"

cat > "$STEP_FILE" <<'JSON'
{"type":"message","step_id":"trig-1","from":"pwa-nick","to":"ada","content":"hello"}
JSON

cat > "$TRAJ_FILE" <<'JSON'
{"type":"trajectory","step_id":"aaaaaaaa"}
{"type":"message","step_id":"trig-1","from":"pwa-nick","to":"ada","content":"hello"}
JSON

cat > "$WORK/shim/identity" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
    prompt) printf 'identity prompt\n' ;;
esac
SHIM

cat > "$WORK/shim/skills" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
    prompt) printf 'skills prompt\n' ;;
esac
SHIM

cat > "$WORK/shim/traj" <<SHIM
#!/usr/bin/env bash
case "\${1:-}" in
    exists) exit 0 ;;
    path) printf '%s\n' "$TRAJ_FILE" ;;
    cat) cat "$TRAJ_FILE" ;;
    append) cat >> "$TRAJ_FILE" ;;
esac
SHIM

cat > "$WORK/shim/llm" <<SHIM
#!/usr/bin/env bash
printf 'partial'
: > "$READY_FILE"
sleep 1
printf ' done'
SHIM

cat > "$WORK/shim/chat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "reply" ]]; then
    cat > "$REPLY_FILE"
    exit 0
fi
exit 1
SHIM

chmod +x "$WORK/shim/identity" "$WORK/shim/skills" "$WORK/shim/traj" \
    "$WORK/shim/llm" "$WORK/shim/chat"

(
    export PATH="$WORK/shim:$PATH"
    export IDENTITY_DIR="$WORK/id" IDENTITY_NAME=ada
    export TRAJ_DIR="$WORK/traj" TRAJ_ID=aaaaaaaa ROOT_TRAJ_ID=aaaaaaaa
    export MEM_DIR="$WORK/id/memories" THINK_MODEL=test-model
    "$REPO/thinkers/responder/step" < "$STEP_FILE"
) > "$WORK/stdout" 2> "$WORK/stderr" &
step_pid=$!

for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$READY_FILE" ]] && break
    sleep 0.1
done

if [[ -f "$PARTIAL_FILE" ]] && grep -q 'partial' "$PARTIAL_FILE"; then
    ok "partial reply is visible while llm is still running"
else
    bad "partial reply is visible while llm is still running" "missing $PARTIAL_FILE"
fi

if [[ ! -s "$REPLY_FILE" ]]; then
    ok "final reply is not sent before generation completes"
else
    bad "final reply is not sent before generation completes"
fi

wait "$step_pid"

if [[ "$(cat "$REPLY_FILE" 2>/dev/null)" == "partial done" ]]; then
    ok "final reply still sends the completed content"
else
    bad "final reply still sends the completed content" "$(cat "$REPLY_FILE" 2>/dev/null)"
fi

if [[ ! -e "$PARTIAL_DIR" ]]; then
    ok "partial reply file is removed after completion"
else
    bad "partial reply file is removed after completion" "$PARTIAL_DIR still exists"
fi

FAIL_STEP_FILE="$WORK/step-fail.json"
FAIL_READY_FILE="$WORK/llm-fail-ready"
FAIL_REPLY_FILE="$WORK/chat-reply-fail"
FAIL_PARTIAL_DIR="$WORK/id/run/responder-partials/trig-fail"

cat > "$FAIL_STEP_FILE" <<'JSON'
{"type":"message","step_id":"trig-fail","from":"pwa-nick","to":"ada","content":"will this fail?"}
JSON

cat >> "$TRAJ_FILE" <<'JSON'
{"type":"message","step_id":"trig-fail","from":"pwa-nick","to":"ada","content":"will this fail?"}
JSON

cat > "$WORK/shim/llm" <<SHIM
#!/usr/bin/env bash
printf 'partial'
: > "$FAIL_READY_FILE"
exit 1
SHIM

cat > "$WORK/shim/chat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "reply" ]]; then
    cat > "$FAIL_REPLY_FILE"
    exit 0
fi
exit 1
SHIM

chmod +x "$WORK/shim/llm" "$WORK/shim/chat"

(
    export PATH="$WORK/shim:$PATH"
    export IDENTITY_DIR="$WORK/id" IDENTITY_NAME=ada
    export TRAJ_DIR="$WORK/traj" TRAJ_ID=aaaaaaaa ROOT_TRAJ_ID=aaaaaaaa
    export MEM_DIR="$WORK/id/memories" THINK_MODEL=test-model
    "$REPO/thinkers/responder/step" < "$FAIL_STEP_FILE"
) > "$WORK/stdout-fail" 2> "$WORK/stderr-fail"

if [[ ! -e "$FAIL_REPLY_FILE" ]]; then
    ok "partial output from failed llm is not sent"
else
    bad "partial output from failed llm is not sent" "$(cat "$FAIL_REPLY_FILE")"
fi

if jq -e 'select(.type == "observation" and .trigger_step == "trig-fail" and (.content | startswith("reply failed")))' "$TRAJ_FILE" >/dev/null; then
    ok "failed llm appends reply-failed observation"
else
    bad "failed llm appends reply-failed observation"
fi

if [[ ! -e "$FAIL_PARTIAL_DIR" ]]; then
    ok "partial reply file is removed after llm failure"
else
    bad "partial reply file is removed after llm failure" "$FAIL_PARTIAL_DIR still exists"
fi

NOREPLY_STEP_FILE="$WORK/step-fail-noreply.json"
NOREPLY_REPLY_FILE="$WORK/chat-reply-fail-noreply"
NOREPLY_PARTIAL_DIR="$WORK/id/run/responder-partials/trig-fail-noreply"

cat > "$NOREPLY_STEP_FILE" <<'JSON'
{"type":"message","step_id":"trig-fail-noreply","from":"pwa-nick","to":"ada","content":"maybe no reply?"}
JSON

cat >> "$TRAJ_FILE" <<'JSON'
{"type":"message","step_id":"trig-fail-noreply","from":"pwa-nick","to":"ada","content":"maybe no reply?"}
JSON

cat > "$WORK/shim/llm" <<'SHIM'
#!/usr/bin/env bash
printf 'NO_REPLY'
exit 1
SHIM

cat > "$WORK/shim/chat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "reply" ]]; then
    cat > "$NOREPLY_REPLY_FILE"
    exit 0
fi
exit 1
SHIM

chmod +x "$WORK/shim/llm" "$WORK/shim/chat"

(
    export PATH="$WORK/shim:$PATH"
    export IDENTITY_DIR="$WORK/id" IDENTITY_NAME=ada
    export TRAJ_DIR="$WORK/traj" TRAJ_ID=aaaaaaaa ROOT_TRAJ_ID=aaaaaaaa
    export MEM_DIR="$WORK/id/memories" THINK_MODEL=test-model
    "$REPO/thinkers/responder/step" < "$NOREPLY_STEP_FILE"
) > "$WORK/stdout-fail-noreply" 2> "$WORK/stderr-fail-noreply"

if [[ ! -e "$NOREPLY_REPLY_FILE" ]]; then
    ok "NO_REPLY from failed llm is not sent"
else
    bad "NO_REPLY from failed llm is not sent" "$(cat "$NOREPLY_REPLY_FILE")"
fi

if jq -e 'select(.type == "observation" and .trigger_step == "trig-fail-noreply" and .decision == "no-reply")' "$TRAJ_FILE" >/dev/null; then
    bad "NO_REPLY from failed llm is not recorded as no-reply"
else
    ok "NO_REPLY from failed llm is not recorded as no-reply"
fi

if jq -e 'select(.type == "observation" and .trigger_step == "trig-fail-noreply" and (.content | startswith("reply failed")))' "$TRAJ_FILE" >/dev/null; then
    ok "NO_REPLY from failed llm appends reply-failed observation"
else
    bad "NO_REPLY from failed llm appends reply-failed observation"
fi

if [[ ! -e "$NOREPLY_PARTIAL_DIR" ]]; then
    ok "partial reply file is removed after NO_REPLY llm failure"
else
    bad "partial reply file is removed after NO_REPLY llm failure" "$NOREPLY_PARTIAL_DIR still exists"
fi

TRAVERSAL_STEP_FILE="$WORK/step-traversal.json"
TRAVERSAL_REPLY_FILE="$WORK/chat-reply-traversal"
RUN_SENTINEL="$WORK/id/run/keep-me"

cat > "$TRAVERSAL_STEP_FILE" <<'JSON'
{"type":"message","step_id":"..","from":"pwa-nick","to":"ada","content":"odd id"}
JSON

cat >> "$TRAJ_FILE" <<'JSON'
{"type":"message","step_id":"..","from":"pwa-nick","to":"ada","content":"odd id"}
JSON

printf 'sentinel' > "$RUN_SENTINEL"

cat > "$WORK/shim/llm" <<'SHIM'
#!/usr/bin/env bash
printf 'safe reply'
SHIM

cat > "$WORK/shim/chat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "reply" ]]; then
    cat > "$TRAVERSAL_REPLY_FILE"
    exit 0
fi
exit 1
SHIM

chmod +x "$WORK/shim/llm" "$WORK/shim/chat"

(
    export PATH="$WORK/shim:$PATH"
    export IDENTITY_DIR="$WORK/id" IDENTITY_NAME=ada
    export TRAJ_DIR="$WORK/traj" TRAJ_ID=aaaaaaaa ROOT_TRAJ_ID=aaaaaaaa
    export MEM_DIR="$WORK/id/memories" THINK_MODEL=test-model
    "$REPO/thinkers/responder/step" < "$TRAVERSAL_STEP_FILE"
) > "$WORK/stdout-traversal" 2> "$WORK/stderr-traversal"

if [[ -e "$RUN_SENTINEL" ]]; then
    ok "malformed step id cleanup keeps unrelated run files"
else
    bad "malformed step id cleanup keeps unrelated run files"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
