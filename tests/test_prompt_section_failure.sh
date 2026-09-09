#!/usr/bin/env bash
# tests/test_prompt_section_failure.sh — a wake prompt section that fails to
# build is loud: stderr names the command, an `error` step lands in the root
# trajectory (reason prompt-section-failed), repeats within the hour are not
# recorded again, and a working section prints its text with no error step.
#
# Why: `skills prompt` failed silently from 2026-08-15 to 2026-09-04 and every
# wake prompt lost its kernel skills; the caller swallowed the exit status.
set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d); trap 'cd /; rm -rf "$WORK"' EXIT
ID="$WORK/ident"; TRAJ_ID="cafe0000-0000-0000-0000-0000000000f1"
mkdir -p "$ID/trajectories/$TRAJ_ID" "$WORK/fakebin"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"; : > "$TRAJ"
export IDENTITY_NAME=ada TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" IDENTITY_DIR="$ID" MEM_DIR="$ID/memories" THINKER_NAME=testthinker

# Fakes: identity works, skills fails (mode file flips it).
cat > "$WORK/fakebin/identity" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "prompt" ]] && printf 'I am Ada.'
SH
cat > "$WORK/fakebin/skills" <<'SH'
#!/usr/bin/env bash
if [[ -f "$SKILLS_MODE" && "$(cat "$SKILLS_MODE")" == "ok" ]]; then printf '## My skills system\nkernel text'; exit 0; fi
echo "skills: boom: no frontmatter" >&2; exit 1
SH
chmod +x "$WORK/fakebin/"*
export SKILLS_MODE="$WORK/mode"; echo fail > "$SKILLS_MODE"
export PATH="$WORK/fakebin:$REPO/bin:$PATH"

build() { ( cd "$WORK" && source "$REPO/thinkers/_lib/common.sh" && _build_system_prompt ); }

out=$(build 2>"$WORK/err1"); rc=$?
check "build still succeeds when a section fails"     test "$rc" -eq 0
check "identity text is present"                     grep -q 'I am Ada' <<<"$out"
check "skills section is absent, not garbage"        bash -c '! grep -q "skills system" <<<"$1"' _ "$out"
check "stderr names the failing command and section" grep -q 'section "skills" failed: `skills prompt` exited 1' "$WORK/err1"
check "stderr carries the command message"   grep -q 'boom: no frontmatter' "$WORK/err1"
n=$(jq -r 'select(.type=="error" and .reason=="prompt-section-failed") | .section' "$TRAJ" | grep -c '^skills$')
check "one error step recorded for the skills section" test "$n" -eq 1
check "error step says the section is missing"       bash -c 'jq -r "select(.type==\"error\") | .content" "$1" | grep -q "missing from every wakeup"' _ "$TRAJ"
check "error step carries the exit code"             bash -c 'jq -s -e "any(.[]; .type==\"error\" and .reason==\"prompt-section-failed\" and .section==\"skills\" and .rc == 1)" "$1"' _ "$TRAJ"

build >/dev/null 2>"$WORK/err2"
n=$(jq -r 'select(.type=="error" and .reason=="prompt-section-failed") | .section' "$TRAJ" | grep -c '^skills$')
check "a repeat within the hour adds no second error step" test "$n" -eq 1
check "but stderr still complains on the repeat"     grep -q 'section "skills" failed' "$WORK/err2"

echo ok > "$SKILLS_MODE"
out=$(build 2>"$WORK/err3")
check "a working section prints its text"            grep -q 'kernel text' <<<"$out"
check "nothing on stderr when all sections build"    test ! -s "$WORK/err3"
n=$(jq -r 'select(.type=="error") | .type' "$TRAJ" | grep -c .)
check "no new error step on success"                 test "$n" -eq 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
