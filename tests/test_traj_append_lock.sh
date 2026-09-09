#!/usr/bin/env bash
# tests/test_traj_append_lock.sh — `traj append` fails fast when it cannot
# create its lock directory, instead of spinning forever (a bridge user with
# read-only access hung for its whole subprocess timeout per send,
# 2026-09-09). Skipped as root, who can write anything. No LLM calls.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d1"
D="$WORK/trajectories/$TRAJ_ID"; mkdir -p "$D"
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00Z"}\n' "$TRAJ_ID" > "$D/trajectory.jsonl"
export TRAJ_DIR="$WORK/trajectories" TRAJ_ID

traj append --field type=thought --field content=hello >/dev/null 2>&1 && ok "append works on a writable directory" || bad "append works"
if [[ "$(id -u)" -eq 0 ]]; then
    ok "skipped the read-only case (running as root)"
else
    chmod 555 "$D"
    start=$SECONDS
    err=$(traj append --field type=thought --field content=again 2>&1 >/dev/null); rc=$?
    took=$((SECONDS - start))
    [[ $rc -ne 0 ]] && ok "append fails on a read-only directory (rc=$rc)" || bad "append fails" "rc=$rc"
    [[ $took -le 3 ]] && ok "it fails fast (${took}s)" || bad "fails fast" "took ${took}s"
    printf '%s' "$err" | grep -q 'cannot create lock' && ok "the error names the lock" || bad "error text" "$err"
    chmod 755 "$D"
    [[ ! -d "$D/trajectory.jsonl.lock" ]] && ok "no lock directory is left behind" || bad "lock left behind"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
