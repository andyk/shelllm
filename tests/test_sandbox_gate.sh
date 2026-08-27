#!/usr/bin/env bash
# tests/test_sandbox_gate.sh — the Docker sandbox consent gate.
#
# Usage: tests/test_sandbox_gate.sh
#
# Why: the agent writes and runs real shell commands; Docker is the sandbox
# for them. headlong-init refuses to start an unsandboxed agent without
# consent (a typed "yes" at a tty, or HEADLONG_UNSANDBOXED=1 without one),
# and when Docker is present it writes SHELLM_REQUIRE_DOCKER=1 so shellm
# hard-fails instead of silently falling back to the host if the daemon
# later dies. Docker is a stub here; no real daemon is touched.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

# Inside a container the gate is bypassed by design (the container is the
# sandbox), so these paths cannot be exercised there.
if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
    echo "ok   skipped: inside a container, where the gate is bypassed by design"
    exit 0
fi

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

# --- stubs -------------------------------------------------------------------
# docker: `info` honors DOCKER_STUB_INFO_RC (0 = daemon up, else down);
# everything else (image inspect, ...) succeeds so no pull is attempted.
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}" in
    info) exit "${DOCKER_STUB_INFO_RC:-0}" ;;
    *)    exit 0 ;;
esac
STUBEOF
chmod +x "$STUB/docker"

# A minimal fake checkout: headlong-init only checks that bin/shellm exists
# under HEADLONG_APP_DIR. Keeping it fake also keeps any real ~/.env or repo
# .env keys out of these runs.
APP="$WORK/app"; mkdir -p "$APP/bin" "$APP/tools"
: > "$APP/bin/shellm"

# run_init <home> [VAR=VAL ...] — run headlong-init with no tty, no API keys,
# and the docker stub first on PATH. Output (stdout+stderr) to $WORK/out.
run_init() {
    local home="$1"; shift
    mkdir -p "$home"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
        -u OPENCODE_API_KEY -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY -u AWS_PROFILE \
        -u HEADLONG_UNSANDBOXED -u HEADLONG_FAKE_DOCKER -u SHELLM_DOCKER_IMAGE -u SHELLM_MODEL \
        HOME="$home" HEADLONG_HOME="$home/.headlong" HEADLONG_APP_DIR="$APP" \
        HEADLONG_NO_TTY=1 PATH="$STUB:$PATH" "$@" \
        bash "$REPO/tools/headlong-init" </dev/null > "$WORK/out" 2>&1
}

# --- headlong-init: no docker, no tty, no consent -> stop at the gate --------
run_init "$WORK/h1" DOCKER_STUB_INFO_RC=1; rc=$?
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }
check "no docker, no consent: exits non-zero"            test "$rc" -ne 0
check "no docker, no consent: names HEADLONG_UNSANDBOXED" grep -q "HEADLONG_UNSANDBOXED" "$WORK/out"
check_not "no docker, no consent: never reaches the key step" grep -qi "API key" "$WORK/out"

# --- headlong-init: no docker, consent via env -> gate passes ----------------
run_init "$WORK/h2" DOCKER_STUB_INFO_RC=1 HEADLONG_UNSANDBOXED=1; rc=$?
check "consented: passes the gate (fails later, at the key step)" grep -q "no API key" "$WORK/out"
check "consented: prints the unsandboxed warning"        grep -qi "directly on this machine" "$WORK/out"
check "consented: SHELLM_REQUIRE_DOCKER=0 in state .env" grep -qx "SHELLM_REQUIRE_DOCKER=0" "$WORK/h2/.headlong/.env"

# --- headlong-init: docker up -> sandbox promised and enforced ---------------
run_init "$WORK/h3" DOCKER_STUB_INFO_RC=0; rc=$?
check "docker up: announces the sandbox"                 grep -q "sandboxed in Docker" "$WORK/out"
check "docker up: SHELLM_REQUIRE_DOCKER=1 in state .env" grep -qx "SHELLM_REQUIRE_DOCKER=1" "$WORK/h3/.headlong/.env"
check "docker up: gate passes (fails later, at the key step)" grep -q "no API key" "$WORK/out"

# --- explicit unsandboxed choice beats a live daemon (installer menu 3) ------
run_init "$WORK/h7" DOCKER_STUB_INFO_RC=0 HEADLONG_UNSANDBOXED=1; rc=$?
check "menu 3: unsandboxed sticks even with docker up"   grep -qx "SHELLM_REQUIRE_DOCKER=0" "$WORK/h7/.headlong/.env"
check "menu 3: choice persisted for re-runs"             grep -qx "HEADLONG_UNSANDBOXED=1" "$WORK/h7/.headlong/.env"
check_not "menu 3: sandbox not announced"                grep -q "sandboxed in Docker" "$WORK/out"

# --- the HEADLONG_FAKE_DOCKER knob overrides real detection ------------------
# The stub daemon answers "up" here, so only the knob can produce these paths.
run_init "$WORK/h4" DOCKER_STUB_INFO_RC=0 HEADLONG_FAKE_DOCKER=missing; rc=$?
check "fake missing: gate stops despite a live daemon"   test "$rc" -ne 0
check "fake missing: names HEADLONG_UNSANDBOXED"         grep -q "HEADLONG_UNSANDBOXED" "$WORK/out"
run_init "$WORK/h5" DOCKER_STUB_INFO_RC=1 HEADLONG_FAKE_DOCKER=ok; rc=$?
check "fake ok: sandbox promised despite a down daemon"  grep -qx "SHELLM_REQUIRE_DOCKER=1" "$WORK/h5/.headlong/.env"

# --- --dry-run: walks the gate, writes nothing, exits 0 ----------------------
mkdir -p "$WORK/h6"
env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
    -u OPENCODE_API_KEY -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID \
    -u AWS_SECRET_ACCESS_KEY -u AWS_PROFILE \
    -u HEADLONG_UNSANDBOXED -u SHELLM_DOCKER_IMAGE -u SHELLM_MODEL \
    HOME="$WORK/h6" HEADLONG_HOME="$WORK/h6/.headlong" HEADLONG_APP_DIR="$APP" \
    HEADLONG_NO_TTY=1 HEADLONG_FAKE_DOCKER=ok PATH="$STUB:$PATH" \
    bash "$REPO/tools/headlong-init" --dry-run > "$WORK/out" 2>&1; rc=$?
check "dry-run: exits 0"                                 test "$rc" -eq 0
check "dry-run: announces the sandbox"                   grep -q "sandboxed in Docker" "$WORK/out"
check "dry-run: says what it would set"                  grep -q "would set SHELLM_REQUIRE_DOCKER=1" "$WORK/out"
check "dry-run: says it stopped"                         grep -qi "dry run" "$WORK/out"
check_not "dry-run: writes no state .env"                test -f "$WORK/h6/.headlong/.env"
env HOME="$WORK/h6" HEADLONG_HOME="$WORK/h6/.headlong" HEADLONG_APP_DIR="$APP" \
    bash "$REPO/tools/headlong-init" --bogus > "$WORK/out" 2>&1; rc=$?
check "unknown option is an error"                       test "$rc" -ne 0

# --- shellm: SHELLM_REQUIRE_DOCKER enforcement -------------------------------
# Same setup as test_prompt_file.sh: a copied bin/ with a stubbed llm so a
# run that legitimately proceeds ends on its first turn, offline.
cp -R "$REPO/bin" "$WORK/toolbin"
cat > "$WORK/toolbin/llm" <<'STUBEOF'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "--thinking" ]] && main_loop=1; done
if [[ "${main_loop:-0}" -ne 1 ]]; then printf '{}\n'; exit 0; fi
printf '```bash\nFINAL=done\n```\n'
STUBEOF
chmod +x "$WORK/toolbin/llm"
cp "$STUB/docker" "$WORK/toolbin/docker"
mkdir -p "$WORK/wd" "$WORK/shome"

run_shellm() {  # run_shellm <SHELLM_REQUIRE_DOCKER value>
    ( cd "$WORK/wd" && \
      env -u SHELLM_ENV DOCKER_STUB_INFO_RC=1 PATH="$WORK/toolbin:$PATH" \
          HOME="$WORK/shome" ANTHROPIC_API_KEY=test-key SHELLM_MODEL=test-model \
          SHELLM_REQUIRE_DOCKER="$1" \
          "$WORK/toolbin/shellm" --max-iterations 1 "say hi" ) \
        > "$WORK/sout" 2> "$WORK/serr" </dev/null
}

run_shellm 1; rc=$?
check "shellm: daemon down + REQUIRE=1 refuses to run"   test "$rc" -ne 0
check "shellm: refusal names SHELLM_REQUIRE_DOCKER"      grep -q "SHELLM_REQUIRE_DOCKER" "$WORK/serr"

run_shellm 0; rc=$?
check "shellm: daemon down + REQUIRE=0 still runs local" test "$rc" -eq 0
check "shellm: local fallback keeps its warning"         grep -q "running on host" "$WORK/serr"

run_shellm 2; rc=$?
check "shellm: REQUIRE=2 is rejected as invalid"         grep -q "Invalid SHELLM_REQUIRE_DOCKER" "$WORK/serr"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
