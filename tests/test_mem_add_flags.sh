#!/usr/bin/env bash
# tests/test_mem_add_flags.sh — `mem add` refuses a flag it does not know
# instead of storing it as the memory's first word (Audel's goal memory read
# "--content Daily papers shortlist..." after `mem add --type goal --content`,
# 2026-09-05). No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
export MEM_DIR="$WORK/mem"; mkdir -p "$MEM_DIR"

err=$(mem add --type goal --content "Daily papers shortlist" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 ]] && ok "an unknown flag after add fails (rc=$rc)" || bad "unknown flag fails"
printf '%s' "$err" | grep -q "unknown option '--content'" && ok "the error names the flag" || bad "error names the flag" "$err"
[[ -z "$(ls "$MEM_DIR")" ]] && ok "nothing is written" || bad "nothing written" "$(ls "$MEM_DIR")"

mem add --type goal --until 2026-09-19 "Daily papers shortlist" >/dev/null 2>&1 && ok "the documented form still works" || bad "documented form"
f=$(ls "$MEM_DIR"/*.md 2>/dev/null | head -1)
grep -q '^type: goal$' "$f" && grep -q '^until: 2026-09-19$' "$f" && ok "type and until land in the frontmatter" || bad "frontmatter" "$(cat "$f")"
grep -q '^Daily papers shortlist$' "$f" && ok "the text is the body" || bad "body" "$(cat "$f")"
printf 'from stdin\n' | mem add --type note >/dev/null 2>&1 && ok "stdin text still works" || bad "stdin"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
