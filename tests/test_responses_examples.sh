#!/usr/bin/env bash
# Hermetic contract tests for docs/examples/responses-request.sh.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE="$REPO/docs/examples/responses-request.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# This is the only llm visible to the worker. It performs no I/O outside the
# fixture and lets each test select an exact lifecycle result.
cat > "$WORK/bin/llm" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'call\n' >> "$STUB_CALLS"
printf '%s\n' "$@" > "$STUB_ARGS"
{
    printf 'format=%s\n' "${LLM_API_FORMAT-}"
    printf 'response=%s\n' "${LLM_RESPONSE_FILE-}"
    printf 'usage=%s\n' "${LLM_USAGE_FILE-}"
    printf 'body=%s\n' "${LLM_RESPONSES_BODY_FILE-}"
    printf 'marker=%s\n' "${FORWARD_MARKER-}"
} > "$STUB_ENV"
printf 'fixture stdout\n'
printf 'fixture stderr\n' >&2
case "${STUB_CASE:-completed}" in
    completed) printf '%s\n' '{"id":"resp_fixture","status":"completed","error":null,"output":[]}' > "$LLM_RESPONSE_FILE" ;;
    incomplete) printf '%s\n' '{"id":"resp_fixture","status":"incomplete","error":null,"output":[]}' > "$LLM_RESPONSE_FILE" ;;
    error) printf '%s\n' '{"id":"resp_fixture","status":"completed","error":{"message":"fixture"},"output":[]}' > "$LLM_RESPONSE_FILE" ;;
    unknown) printf '%s\n' '{"id":"resp_fixture","status":"mystery","error":null,"output":[]}' > "$LLM_RESPONSE_FILE" ;;
    malformed) printf '%s\n' '{not json' > "$LLM_RESPONSE_FILE" ;;
    missing) : ;;
    child_failure) printf '%s\n' '{"id":"resp_fixture","status":"completed","error":null,"output":[]}' > "$LLM_RESPONSE_FILE"; exit 7 ;;
    wait_term)
        trap 'printf received > "$STUB_TERM_SEEN"; exit 143' TERM
        printf ready > "$STUB_READY"
        while :; do sleep 1; done
        ;;
esac
STUB
chmod +x "$WORK/bin/llm"

export PATH="$WORK/bin:$PATH"
export STUB_CALLS="$WORK/calls" STUB_ARGS="$WORK/args" STUB_ENV="$WORK/env"
INPUT="$WORK/input.json"; BODY="$WORK/body.json"
printf '%s\n' '[{"role":"user","content":"fixture"}]' > "$INPUT"
printf '%s\n' '{"reasoning":{"effort":"low"}}' > "$BODY"

rm -f "$STUB_CALLS"
check "no arguments prints help and exits zero" bash -c 'bash "$1" >"$2" 2>"$3"' _ "$EXAMPLE" "$WORK/help.out" "$WORK/help.err"
check "no arguments does not dispatch" test ! -e "$STUB_CALLS"
rm -f "$STUB_CALLS"
check "--help exits zero" bash -c 'bash "$1" --help >"$2" 2>"$3"' _ "$EXAMPLE" "$WORK/help2.out" "$WORK/help2.err"
check "--help does not dispatch" test ! -e "$STUB_CALLS"

printf '%s\n' '{}' > "$WORK/not-array.json"
rm -f "$STUB_CALLS"; INVALID_OUT="$WORK/invalid-input-out"
check "non-array input is rejected" bash -c '! bash "$1" "$2" "$3" >/dev/null 2>&1' _ "$EXAMPLE" "$INVALID_OUT" "$WORK/not-array.json"
check "input validates before output directory creation" test ! -e "$INVALID_OUT"
check "invalid input does not dispatch" test ! -e "$STUB_CALLS"
printf '%s\n' '[]' > "$WORK/not-object.json"
rm -f "$STUB_CALLS"; INVALID_BODY_OUT="$WORK/invalid-body-out"
check "non-object body is rejected" bash -c '! bash "$1" "$2" "$3" "$4" >/dev/null 2>&1' _ "$EXAMPLE" "$INVALID_BODY_OUT" "$INPUT" "$WORK/not-object.json"
check "body validates before output directory creation" test ! -e "$INVALID_BODY_OUT"
check "invalid body does not dispatch" test ! -e "$STUB_CALLS"

OUT="$WORK/completed"; rm -f "$STUB_CALLS"
export STUB_CASE=completed FORWARD_MARKER=forwarded
if bash "$EXAMPLE" "$OUT" "$INPUT" "$BODY" > "$WORK/worker.out" 2> "$WORK/worker.err"; then
    ok "completed valid response exits zero"
else
    bad "completed valid response exits zero"
fi
check "exactly one create request is made" test "$(wc -l < "$STUB_CALLS")" -eq 1
check "input file and fixed request flags are forwarded" grep -Fxq -- "--messages-file" "$STUB_ARGS"
check "input path is forwarded" grep -Fxq -- "$INPUT" "$STUB_ARGS"
check "body file and caller environment are forwarded" bash -c 'grep -Fxq "body=$1" "$2" && grep -Fxq marker=forwarded "$2"' _ "$BODY" "$STUB_ENV"
check "Responses API and evidence paths are forwarded" bash -c 'grep -Fxq format=responses "$1" && grep -Fxq "response=$2/response.json" "$1" && grep -Fxq "usage=$2/usage.json" "$1"' _ "$STUB_ENV" "$OUT"
check "output directory is private (0700)" test "$(mode "$OUT")" = 700
check "response evidence is private (0600)" test "$(mode "$OUT/response.json")" = 600
check "stdout evidence is preserved" grep -Fxq 'fixture stdout' "$OUT/stdout.txt"
check "stderr evidence is preserved" grep -Fxq 'fixture stderr' "$OUT/stderr.txt"
check "completed outcome is preserved and printed" bash -c 'jq -e '\''.outcome == "completed" and .exit_code == 0'\'' "$1/outcome.json" >/dev/null && cmp -s "$1/outcome.json" "$2"' _ "$OUT" "$WORK/worker.out"

mkdir "$WORK/existing"; printf sentinel > "$WORK/existing/sentinel"; before=$(wc -l < "$STUB_CALLS")
check "an existing output directory is rejected" bash -c '! bash "$1" "$2" "$3" >/dev/null 2>&1' _ "$EXAMPLE" "$WORK/existing" "$INPUT"
check "existing evidence is not overwritten or dispatched" bash -c 'test -f "$1/sentinel" && test "$(wc -l < "$2")" -eq "$3"' _ "$WORK/existing" "$STUB_CALLS" "$before"

for case_name in incomplete error unknown malformed missing child_failure; do
    export STUB_CASE="$case_name"
    CASE_OUT="$WORK/$case_name"
    before=$(wc -l < "$STUB_CALLS")
    if bash "$EXAMPLE" "$CASE_OUT" "$INPUT" > "$WORK/$case_name.out" 2> "$WORK/$case_name.err"; then
        bad "$case_name result exits nonzero"
    else
        ok "$case_name result exits nonzero"
    fi
    check "$case_name result is needs_review" jq -e '.outcome == "needs_review" and .exit_code != 0' "$CASE_OUT/outcome.json"
    check "$case_name result is not retried" test "$(wc -l < "$STUB_CALLS")" -eq $((before + 1))
done
check "failed child exit code is preserved" jq -e '.exit_code == 7' "$WORK/child_failure/outcome.json"
check "failed child streams and response are preserved" bash -c 'grep -Fxq "fixture stdout" "$1/stdout.txt" && grep -Fxq "fixture stderr" "$1/stderr.txt" && test -s "$1/response.json"' _ "$WORK/child_failure"

export STUB_CASE=wait_term STUB_READY="$WORK/ready" STUB_TERM_SEEN="$WORK/term-seen"
SIGNAL_OUT="$WORK/signalled"
bash "$EXAMPLE" "$SIGNAL_OUT" "$INPUT" > "$WORK/signalled.out" 2> "$WORK/signalled.err" & worker=$!
for _ in $(seq 1 100); do [[ -e "$STUB_READY" ]] && break; sleep 0.02; done
if [[ -e "$STUB_READY" ]]; then kill -TERM "$worker"; fi
signal_rc=0; wait "$worker" || signal_rc=$?
check "TERM is forwarded to the owned child" test -e "$STUB_TERM_SEEN"
check "worker waits and exits nonzero after TERM" test "$signal_rc" -ne 0
check "interrupted request records needs_review" jq -e '.outcome == "needs_review" and .exit_code != 0' "$SIGNAL_OUT/outcome.json"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
