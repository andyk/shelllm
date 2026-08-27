#!/usr/bin/env bash
# tests/test_var_secrets.sh — secrets passed to shellm stay off command lines.
#
# Usage: tests/test_var_secrets.sh
#
# Covers:
#   1. `--var NAME` (bare) forwards NAME from shellm's environment into the
#      generated code; `--var NAME` with NAME unset is a clear error.
#   2. While the generated code runs, the secret's value appears in no
#      process's argv (`ps`): not shellm's, not `env`'s, not bash's.
#   3. The shellm-run trajectory row records the command with legacy
#      `--var SOME_KEY=value` values masked, and the literal value is
#      nowhere under the state home.
#
# `llm` is stubbed (canned fenced blocks, no network), same pattern as
# tests/test_inactivity_beacon.sh. Local execution is pinned: shellm would
# otherwise enter Docker mode wherever `docker info` works.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- llm stub ----------------------------------------------------------------
mkdir -p "$WORK/script" "$WORK/home" "$WORK/wd"
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUB'
#!/usr/bin/env bash
# Only the main loop passes --thinking; the background run-summary call gets {}.
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
n=$(( $(cat "$LLM_COUNT" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$LLM_COUNT"
if [[ -f "$LLM_SCRIPT/$n" ]]; then cat "$LLM_SCRIPT/$n"; else cat "$LLM_SCRIPT/last"; fi
STUB
chmod +x "$WORK/toolbin/llm"
cat > "$WORK/toolbin/aws" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "configure export-credentials --profile sandbox-profile --format process" ]]; then
    printf '{"Version":1,"AccessKeyId":"PROFILEACCESS","SecretAccessKey":"profile-secret-value","SessionToken":"profile-session-value"}\n'
    exit 0
fi
exit 1
STUB
chmod +x "$WORK/toolbin/aws"

export PATH="$WORK/toolbin:$PATH"
export LLM_COUNT="$WORK/count"
export LLM_SCRIPT="$WORK/script"
export HOME="$WORK/home"
export HEADLONG_HOME="$WORK/home/.headlong"
export ANTHROPIC_API_KEY="test-key"
export SHELLM_MODEL="test-model"
export SHELLM_ENV=local

fence() { printf '```bash\n%s\n```\n' "$1"; }

run_shellm() {
    : > "$LLM_COUNT"
    ( cd "$WORK/wd" && "$WORK/toolbin/shellm" --workdir "$WORK/wd" --max-iterations 2 "$@" ) \
        > "$WORK/out" 2> "$WORK/err" < /dev/null
}

# Generated at runtime so the literals exist nowhere on disk or in any argv
# (this script's own text included) unless something actually leaks them.
SECRET="sk-test-secret-$$-$RANDOM$RANDOM"
LEGACY="sk-legacy-literal-$$-$RANDOM$RANDOM"

# --- 1. bare --var with the variable unset is an error ------------------------
unset SECRET_PROBE
run_shellm --var SECRET_PROBE "task"
if [[ $? -ne 0 ]] && grep -q 'SECRET_PROBE: not set' "$WORK/err"; then
    ok "--var NAME with NAME unset fails with a clear message"
else
    bad "--var NAME with NAME unset fails with a clear message" "$(tail -2 "$WORK/err")"
fi

# --- 2. forwarded value reaches the code; nothing carries it in argv ----------
export SECRET_PROBE="$SECRET"
fence "printf 'got=%s plain=%s\\n' \"\$SECRET_PROBE\" \"\$PLAIN\" > '$WORK/probe.txt'
ps -axo args= > '$WORK/ps.txt' 2>/dev/null || ps -eo args= > '$WORK/ps.txt'" > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"
run_shellm --var SECRET_PROBE --var PLAIN=1 --var "OPENROUTER_API_KEY=$LEGACY" "task"
if grep -qx "got=$SECRET plain=1" "$WORK/probe.txt" 2>/dev/null; then
    ok "bare --var NAME forwards the value into the generated code"
else
    bad "bare --var NAME forwards the value into the generated code" "probe: $(cat "$WORK/probe.txt" 2>/dev/null) err: $(tail -2 "$WORK/err")"
fi
if [[ -s "$WORK/ps.txt" ]]; then
    if ! grep -qF "$SECRET" "$WORK/ps.txt"; then
        ok "forwarded secret is in no process's argv while the code runs"
    else
        bad "forwarded secret is in no process's argv while the code runs" "$(grep -F "$SECRET" "$WORK/ps.txt" | cut -c1-160 | head -3)"
    fi
    # The legacy NAME=VALUE form is on shellm's own argv by construction (the
    # caller put it there; shellm's forked subshells repeat that same line).
    # What must not happen is env/docker re-exposing it under a second,
    # different command line. So: at most one DISTINCT argv line carries it,
    # and it is the shellm invocation, not an `env`/`docker` child.
    distinct=$(grep -F "$LEGACY" "$WORK/ps.txt" | sed 's/^ *//' | sort -u)
    n=$(printf '%s\n' "$distinct" | grep -c .)
    if [[ "$n" -le 1 ]] && ! grep -qE '^(env |docker )' <<<"$distinct"; then
        ok "legacy --var NAME=VALUE is not re-exposed by a child process (distinct argv lines: $n)"
    else
        bad "legacy --var NAME=VALUE is not re-exposed by a child process" "$(printf '%s' "$distinct" | cut -c1-120 | head -4)"
    fi
else
    bad "ps snapshot taken from inside the generated code" "ps.txt empty"
fi

# --- 3. recorded command is redacted; literal value nowhere in state ----------
row=$(grep -rh '"type":"shellm-run"' "$HEADLONG_HOME" 2>/dev/null | tail -1)
if [[ -n "$row" ]] && grep -qF 'OPENROUTER_API_KEY=<redacted>' <<<"$row" && ! grep -qF "$LEGACY" <<<"$row"; then
    ok "shellm-run row masks credential-looking --var values"
else
    bad "shellm-run row masks credential-looking --var values" "$(printf '%s' "$row" | cut -c1-200)"
fi
if grep -qF -- '--var SECRET_PROBE --var PLAIN=1' <<<"$row"; then
    ok "shellm-run row keeps the bare name and non-secret vars readable"
else
    bad "shellm-run row keeps the bare name and non-secret vars readable" "$(printf '%s' "$row" | cut -c1-200)"
fi
hits=$(grep -rlF "$LEGACY" "$HEADLONG_HOME" "$WORK/wd" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" -eq 0 ]]; then
    ok "legacy literal value is nowhere under the state home or workdir"
else
    bad "legacy literal value is nowhere under the state home or workdir" "$(grep -rlF "$LEGACY" "$HEADLONG_HOME" "$WORK/wd" | head -3)"
fi
hits=$(grep -rlF "$SECRET" "$HEADLONG_HOME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$hits" -eq 0 ]]; then
    ok "forwarded secret is nowhere under the state home"
else
    bad "forwarded secret is nowhere under the state home" "$(grep -rlF "$SECRET" "$HEADLONG_HOME" | head -3)"
fi

# --- 4. AWS profile credentials are resolved on the host for generated code --
unset ANTHROPIC_API_KEY AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
export AWS_PROFILE=sandbox-profile AWS_REGION=us-east-1
export SHELLM_MODEL=openai.gpt-5.6-sol
fence "printf '%s %s %s' \"\$AWS_ACCESS_KEY_ID\" \"\$AWS_SECRET_ACCESS_KEY\" \"\$AWS_SESSION_TOKEN\" > '$WORK/aws-profile.txt'
ps -axo args= > '$WORK/aws-profile-ps.txt' 2>/dev/null || ps -eo args= > '$WORK/aws-profile-ps.txt'" > "$WORK/script/1"
fence 'FINAL=done' > "$WORK/script/last"
run_shellm "profile task"
if grep -qx 'PROFILEACCESS profile-secret-value profile-session-value' "$WORK/aws-profile.txt" 2>/dev/null; then
    ok "AWS profile credentials reach generated code"
else
    bad "AWS profile credentials reach generated code" "$(cat "$WORK/aws-profile.txt" 2>/dev/null)"
fi
if ! grep -qF 'profile-secret-value' "$WORK/aws-profile-ps.txt" 2>/dev/null; then
    ok "resolved AWS profile secret stays off process argv"
else
    bad "resolved AWS profile secret stays off process argv" "secret found in ps snapshot"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
