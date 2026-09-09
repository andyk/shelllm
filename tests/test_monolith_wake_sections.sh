#!/usr/bin/env bash
# tests/test_monolith_wake_sections.sh — the monolith's related-memories
# section and goal-review hint (design/related_memories.md). Drives
# thinkers/monolith/step against a throwaway identity with a stubbed shellm
# that captures the --prompt-file. Pins: the section appears with a memory
# matched to the stream, the names shown land in the state file and are not
# shown again next wake, MONOLITH_RELATED_MEMORIES=0 removes the section, the
# goal-review hint fires on the first wake and not on the next, and the
# active-goals section lists a todo with its type.
set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$(dirname "$HERE")"; STEP="$REPO/thinkers/monolith/step"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
WORK=$(mktemp -d); trap 'cd /; rm -rf "$WORK"' EXIT
ID="$WORK/ident"; TRAJ_ID="cafe0000-0000-0000-0000-0000000000bb"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run" "$WORK/stub" "$WORK/home"
printf 'name=testid\ncreated=test\nroot_trajectory=%s\n' "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"; : > "$TRAJ"
printf 'test-token\n' > "$ID/run/dispatcher.token"
cat > "$WORK/stub/shellm" <<'STUB'
#!/usr/bin/env bash
if [[ -n "${STUB_FAIL:-}" ]]; then printf 'Iteration 1 — calling test-model...\nllm: API error: 502 upstream unavailable\n' >&2; exit 1; fi
prev=""
for a in "$@"; do [[ "$prev" == "--prompt-file" ]] && cp "$a" "$STUB_CAPTURE"; prev="$a"; done
printf '{"step_id":"obs-%s","type":"observation","content":"did a thing","source":"monolith","ts":"%s"}\n' "$RANDOM" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STUB_TRAJ"
exit 0
STUB
chmod +x "$WORK/stub/shellm"
export STUB_CAPTURE="$WORK/prompt" STUB_TRAJ="$TRAJ" SHELLM_MODEL=test-model
STATE="$ID/run/monolith_backoff_state.json"
mk() { printf -- '---\nid: x\nsummary: s\ntype: %s\ncreated: %s\n---\n\n%s\n' "$2" "$3" "$4" > "$ID/memories/$1.md"; }
mk 2026-08-20-00-00-00_a1_gh   fact "2026-08-20 00:00:00" "GitHub write on this box: gh is logged in as headlong42, pull-only on laude-institute"
mk 2026-08-21-00-00-00_b2_disp fact "2026-08-21 00:00:00" "The dispatcher token file arms the wake and lives under run/"
mk 2026-08-22-00-00-00_c3_todo todo "2026-08-22 00:00:00" "Ping Braden about the temporal test"
printf '{"step_id":"t1","type":"thought","content":"I should check the github pull-only login headlong42 before the PR work","source":"monolith","ts":"2026-09-04T00:00:00Z"}\n' >> "$TRAJ"
mkdir -p "$ID/workdir/notes"; printf 'a\n' > "$ID/workdir/notes/a.md"; printf 'b\n' > "$ID/workdir/notes/b.md"

run_step() {  # $1 = trigger json, then env overrides
    local trig="$1"; shift
    printf '%s' "$trig" | env PATH="$WORK/stub:$REPO/bin:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME=testid MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        MONOLITH_TIERED_MEMORY=0 MONOLITH_SHARE_HINT_EVERY=0 "$@" "$STEP" >> "$WORK/step.log" 2>&1
}
WAKE='{"type":"monolith-wake","content":"wake","source":"monolith-timer"}'

# Two outbound messages before the first wake: one the bridge confirmed, one
# it could not deliver (design/outbound_delivery.md, part 5).
now_ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"step_id":"m1","type":"message","from":"testid","to":"slack-C0BMVH6LM4K","content":"papers for today","source":"chat","ts":"%s"}\n' "$now_ts" >> "$TRAJ"
printf '{"step_id":"d1","type":"delivery","source":"slack-bridge","transport":"slack","trigger_step":"m1","status":"delivered","channel":"C0BMVH6LM4K","ts":"%s"}\n' "$now_ts" >> "$TRAJ"
printf '{"step_id":"m2","type":"message","from":"testid","to":"slack-nick","content":"lost note","source":"chat","ts":"%s"}\n' "$now_ts" >> "$TRAJ"
printf '{"step_id":"d2","type":"delivery","source":"slack-bridge","transport":"slack","trigger_step":"m2","status":"failed","reason":"unknown slack address form","ts":"%s"}\n' "$now_ts" >> "$TRAJ"

run_step "$WAKE"
p=$(cat "$STUB_CAPTURE" 2>/dev/null)
grep -q '^Sent in the last 24h' <<<"$p" && ok "the sent section is in the wake prompt" || bad "sent section present"
grep -q 'to slack-C0BMVH6LM4K: delivered "papers for today"' <<<"$p" && ok "a delivered send is listed as delivered" || bad "delivered line" "$(grep 'to slack-' <<<"$p")"
grep -q 'to slack-nick: FAILED, never arrived (unknown slack address form) "lost note"' <<<"$p" && ok "a failed send is listed with its reason" || bad "failed line" "$(grep 'to slack-' <<<"$p")"
grep -q '^Related memories' <<<"$p" && ok "the related-memories section is in the wake prompt" || bad "related section present" "$(grep -c . <<<"$p") lines"
grep -q '^Runtime: headlong [0-9a-f]\{7,\} (' <<<"$p" && ok "the runtime line names the checked-out commit" || bad "runtime line present"
grep -q '^Workspace: ' <<<"$p" && ok "the workspace section is in the wake prompt" || bad "workspace section present"
grep -q '^- notes/ 2 files' <<<"$p" && ok "the workspace section counts files per directory" || bad "workspace dir count" "$(grep '^- ' <<<"$p" | head -3)"
grep -q 'No WORKSPACE.md yet' <<<"$p" && ok "the workspace section invites a WORKSPACE.md when none exists" || bad "workspace invite"
grep -q 'a1_gh \[fact, ' <<<"$p" && ok "the memory matched to the stream is listed with its type" || bad "matched memory listed"
grep -q 'GOAL REVIEW (about once a week)' <<<"$p" && ok "the goal-review hint fires on the first wake" || bad "goal review hint fires"
grep -q '\[todo, ' <<<"$p" && ok "the active-goals section shows the todo with its type" || bad "goals section shows todo"
jq -e '.related_prev | index("2026-08-20-00-00-00_a1_gh")' "$STATE" >/dev/null 2>&1 && ok "the names shown are saved in the state file" || bad "state file has related_prev" "$(cat "$STATE" 2>/dev/null)"
[[ "$(jq -r '.goal_review_at' "$STATE" 2>/dev/null)" -gt 0 ]] && ok "the goal-review time is saved" || bad "goal_review_at saved"

run_step "$WAKE"
p2=$(cat "$STUB_CAPTURE")
if grep -q '^Related memories' <<<"$p2"; then
    grep -q 'a1_gh' <<<"$p2" && bad "a memory shown last wake is not shown again" || ok "a memory shown last wake is not shown again"
else
    ok "a memory shown last wake is not shown again (nothing else matched, section omitted)"
fi
grep -q 'GOAL REVIEW (about once a week)' <<<"$p2" && bad "the goal-review hint does not repeat within the period" || ok "the goal-review hint does not repeat within the period"

rm -f "$STATE"; run_step "$WAKE" MONOLITH_RELATED_MEMORIES=0 MONOLITH_GOAL_REVIEW_DAYS=0
p3=$(cat "$STUB_CAPTURE")
grep -q '^Related memories' <<<"$p3" && bad "MONOLITH_RELATED_MEMORIES=0 removes the section" || ok "MONOLITH_RELATED_MEMORIES=0 removes the section"
grep -q 'GOAL REVIEW (about once a week)' <<<"$p3" && bad "MONOLITH_GOAL_REVIEW_DAYS=0 disables the hint" || ok "MONOLITH_GOAL_REVIEW_DAYS=0 disables the hint"

# A run that dies with no durable step records why (the last stderr lines).
run_step "$WAKE" STUB_FAIL=1
e=$(grep '"reason":"run-failed"' "$TRAJ" | tail -1)
printf '%s' "$e" | jq -e '.rc == 1 and (.stderr_tail | test("502 upstream")) and (.content | test("502 upstream"))' >/dev/null 2>&1 \
    && ok "a failed run's error step carries the last stderr lines" || bad "failed run reason" "$e"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
