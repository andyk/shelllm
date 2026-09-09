#!/usr/bin/env bash
# tests/test_traj_search.sh — `traj search` prefilters rows with one grep and
# takes --tail N, so a self-check on a long log finishes; blob-backed output is
# still searched. No LLM calls, no docker.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
TRAJ_ID="cafe0000-0000-0000-0000-0000000000d0"
mkdir -p "$WORK/trajectories/$TRAJ_ID/blobs"
T="$WORK/trajectories/$TRAJ_ID/trajectory.jsonl"
export TRAJ_DIR="$WORK/trajectories" TRAJ_ID
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00Z"}\n' "$TRAJ_ID" > "$T"
printf '{"step_id":"s1","type":"reasoning","cmd":"chat send --to slack-C1 \\"Dr. Claw paper\\"","ts":"2026-01-01T00:00:01Z"}\n' >> "$T"
printf '{"step_id":"s2","type":"shell-output","stdout":"nothing here","ts":"2026-01-01T00:00:02Z"}\n' >> "$T"
printf 'RISE paper in a blob\n' > "$WORK/trajectories/$TRAJ_ID/blobs/b1.txt"
printf '{"step_id":"s3","type":"shell-output","stdout":"[blob]","stdout_ref":"blobs/b1.txt","ts":"2026-01-01T00:00:03Z"}\n' >> "$T"
printf '{"step_id":"s4","type":"reasoning","cmd":"echo later","ts":"2026-01-01T00:00:04Z"}\n' >> "$T"

out=$(traj search "Dr. Claw")
[[ "$out" == "s1:cmd:"* ]] && [[ $(printf '%s\n' "$out" | grep -c .) -eq 1 ]] && ok "a literal match is found in the row's field" || bad "literal match" "$out"
out=$(traj search -i "dr. claw")
[[ "$out" == "s1:cmd:"* ]] && ok "-i is honoured by the prefilter" || bad "-i" "$out"
out=$(traj search "RISE paper")
[[ "$out" == "s3:stdout:"* ]] && ok "text that lives in a blob is still searched" || bad "blob search" "$out"
out=$(traj search "Dr. Claw" --tail 2)
[[ -z "$out" ]] && ok "--tail 2 does not reach an older row" || bad "--tail bounds" "$out"
out=$(traj search "later" --tail 2)
[[ "$out" == "s4:cmd:"* ]] && ok "--tail 2 still finds a recent row" || bad "--tail recent" "$out"
out=$(traj search -E 'Dr\. (Claw|Paw)')
[[ "$out" == "s1:cmd:"* ]] && ok "-E regex works through the prefilter" || bad "-E" "$out"
traj search "x" --tail abc >/dev/null 2>&1 && bad "--tail rejects non-numbers" || ok "--tail rejects non-numbers"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
