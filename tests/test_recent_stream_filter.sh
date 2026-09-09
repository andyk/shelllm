#!/usr/bin/env bash
# tests/test_recent_stream_filter.sh — the recent-stream filter thinkers read
# (design/conversation_memory.md, part 3; Experiment B).
#
# Usage: tests/test_recent_stream_filter.sh
#
# Builds a trajectory by hand and calls _recent_stream from thinkers/_lib.
# Pins: reasoning steps are dropped, final steps kept, runs of consecutive idle
# (and error) steps collapse into one line with a count and duration, idles
# separated by another step are not merged, order is preserved, content is
# still truncated at 1500 characters, and the window (N) bounds the raw steps
# considered before collapsing. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ef"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
export IDENTITY_NAME=ada TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" IDENTITY_DIR="$ID" MEM_DIR="$ID/memories"

# ts <minutes ago> — fixed base so durations are deterministic
ts() { python3 -c "import datetime as d; print((d.datetime(2026,9,2,12,0,tzinfo=d.timezone.utc)-d.timedelta(minutes=$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z'))"; }
step() {  # step <id> <type> <content> <minutes-ago> [extra json fields]
    printf '{"step_id":"%s","type":"%s","content":%s,"ts":"%s","source":"monolith"%s}\n' \
        "$1" "$2" "$(printf '%s' "$3" | jq -Rsa .)" "$(ts "$4")" "${5:-}" >> "$TRAJ"
}

stream() {  # stream <N> — run _recent_stream in a subshell with the lib sourced
    (
        # shellcheck disable=SC1091
        source "$REPO/thinkers/_lib/common.sh"
        _recent_stream "$1"
    )
}

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(ts 9999)" >> "$TRAJ"
step t1  thought   "first thought"                       300
step r1  reasoning "Chat-first this tick: last-word..."  299
step so1 shell-output "output"                           298
step f1  final     "run concluded: nothing to do"        297 ',"run_id":"run-0001"'
step i1  idle idle 290
step i2  idle idle 200
step i3  idle idle 170   # i1..i3: 2h over 290 -> 170 min ago
step m1  message   "hey"                                 100 ',"from":"nick","to":"ada"'
step i4  idle idle 90    # separated from i1..i3 by the message: its own run
step e1  error "monolith run failed (rc=1) with no durable step" 60 ',"rc":1,"reason":"run-failed"'
step e2  error "monolith run failed (rc=1) with no durable step" 20 ',"rc":1,"reason":"run-failed"'
step r2  reasoning "more prose"                          10
step t2  thought   "$(head -c 2000 /dev/zero | tr '\0' x)" 5

out=$(stream 30)
types=$(printf '%s\n' "$out" | jq -r .type | tr '\n' ' ')

if ! printf '%s\n' "$out" | jq -e 'select(.type == "reasoning")' >/dev/null 2>&1; then
    ok "reasoning steps are dropped"
else
    bad "reasoning steps are dropped" "$types"
fi
if ! printf '%s\n' "$out" | jq -e 'select(.type == "shell-output")' >/dev/null 2>&1; then
    ok "machinery steps stay out"
else
    bad "machinery steps stay out"
fi
printf '%s\n' "$out" | jq -e 'select(.step_id == "f1")' >/dev/null 2>&1 && ok "final steps are kept" || bad "final steps are kept" "$types"
# A final is all the next wake sees of its run, so it carries a command that
# prints the run's raw steps; a final without a run id (old rows) carries none.
details=$(printf '%s\n' "$out" | jq -r 'select(.step_id == "f1") | .details // "none"')
[[ "$details" == "traj tail -n 400 --filter run_id=run-0001" ]] && ok "finals carry a details command for their run" || bad "finals carry a details command for their run" "got: $details"


idle_lines=$(printf '%s\n' "$out" | jq -c 'select(.type == "idle")')
n_idle=$(printf '%s\n' "$idle_lines" | grep -c . || true)
[[ "$n_idle" == 2 ]] && ok "two idle runs become two lines (the message splits them)" || bad "two idle runs become two lines" "got $n_idle: $idle_lines"
first_idle=$(printf '%s\n' "$idle_lines" | head -1)
if [[ "$(printf '%s' "$first_idle" | jq -r .content)" == "idle x3 over 2h0m" \
      && "$(printf '%s' "$first_idle" | jq -r .collapsed)" == 3 \
      && "$(printf '%s' "$first_idle" | jq -r .step_id)" == i3 ]]; then
    ok "a run of 3 idles collapses to 'idle x3 over 2h0m', carrying the last step id"
else
    bad "a run of 3 idles collapses with count and duration" "got $first_idle"
fi
second_idle=$(printf '%s\n' "$idle_lines" | tail -1)
if [[ "$(printf '%s' "$second_idle" | jq -r .content)" == idle && "$(printf '%s' "$second_idle" | jq 'has("collapsed")')" == false ]]; then
    ok "a lone idle is left as it was"
else
    bad "a lone idle is left as it was" "got $second_idle"
fi

err=$(printf '%s\n' "$out" | jq -c 'select(.type == "error")')
n_err=$(printf '%s\n' "$err" | grep -c . || true)
if [[ "$n_err" == 1 && "$(printf '%s' "$err" | jq -r .content)" == "run failed x2 over 40m (rc=1)" ]]; then
    ok "error steps are in, and a run of them collapses with the rc"
else
    bad "error steps are in and collapse" "got $err"
fi

order=$(printf '%s\n' "$out" | jq -r .step_id | tr '\n' ' ')
[[ "$order" == "t1 f1 i3 m1 i4 e2 t2 " ]] && ok "order is preserved" || bad "order is preserved" "got $order"

len=$(printf '%s\n' "$out" | jq -r 'select(.step_id == "t2") | .content | length')
[[ "$len" -le 1520 ]] && ok "long content is still truncated" || bad "long content is still truncated" "got $len"

# The window bounds raw kept steps before collapsing: N=3 sees e1 e2 t2 only
out3=$(stream 3)
order3=$(printf '%s\n' "$out3" | jq -r .step_id | tr '\n' ' ')
[[ "$order3" == "e2 t2 " ]] && ok "N bounds the raw steps considered (3 kept -> 2 lines after collapsing)" || bad "N bounds the raw steps considered" "got $order3"

# Every output line is still one JSON object callers can parse
if printf '%s\n' "$out" | jq -e . >/dev/null 2>&1; then
    ok "output is one JSON object per line"
else
    bad "output is one JSON object per line"
fi

# Responder observations carry metrics (context_steps, compose_ms, model, ...)
# for the metrics scripts, not for the mind: they are dropped. Ids are cut
# to 8 characters; trigger_step and resolves stay whole.
step ro observation "Replied to nick" 3 ',"decision":"replied","trigger_step":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","context_steps":["11111111-2222-3333-4444-555555555555","66666666-7777-8888-9999-000000000000"],"context_msgs":18,"compose_ms":30249,"model":"x-ai/grok-4.6","history_source":"index","run_id":"12345678-abcd-ef01-2345-6789abcdef01"'
ro=$(stream 30 | jq -c 'select(.content == "Replied to nick")')
if [[ -n "$ro" ]] && ! printf '%s' "$ro" | grep -q -e context_steps -e compose_ms -e '"model"' -e history_source \
   && [[ "$(printf '%s' "$ro" | jq -r '.decision + " " + .trigger_step + " " + .run_id + " " + (.ts|length|tostring)')" == "replied aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee 12345678 16" ]]; then
    ok "responder metrics are dropped; ids are short, trigger_step whole"
else
    bad "responder metrics are dropped; ids are short, trigger_step whole" "$ro"
fi

# A final without a run id (old rows) carries no details command.
step f2 final "old final, no run id" 4
printf '%s\n' "$(stream 30)" | jq -e 'select(.step_id == "f2") | has("details") | not' >/dev/null 2>&1 && ok "a final without a run id carries no details" || bad "a final without a run id carries no details"

# Observation/final pairs: a final drops the nearest earlier observation of
# its run; earlier milestones, orphan observations, and orphan finals stay.
step o1 observation "milestone 1 of run 2"  3 ',"run_id":"run-0002","source":"monolith"'
step o2 observation "run 2 done (handoff)"  2 ',"run_id":"run-0002","source":"monolith"'
step f3 final       "run 2 done (handoff)"  2 ',"run_id":"run-0002"'
step o3 observation "run 3 never finished"  1 ',"run_id":"run-0003","source":"monolith"'
ids=$(stream 40 | jq -r .step_id | tr '\n' ' ')
case "$ids" in *" o2 "*) bad "the observation paired with a final is dropped" "got $ids" ;; *) ok "the observation paired with a final is dropped" ;; esac
case "$ids" in *" o1 f3 "*) ok "an earlier in-run observation stays as a milestone" ;; *) bad "an earlier in-run observation stays" "got $ids" ;; esac
case "$ids" in *" o3 "*) ok "an observation whose run had no final stays" ;; *) bad "an orphan observation stays" "got $ids" ;; esac
case "$ids" in *" f1 "*) ok "a final with no observation stays" ;; *) bad "an orphan final stays" "got $ids" ;; esac
case "$ids" in *" ro "*) ok "a responder observation (other run id) is untouched" ;; *) bad "responder observation untouched" "got $ids" ;; esac
# The pairing runs before the tail cut, so N still counts distinct events.
ids2=$(stream 2 | jq -r .step_id | tr '\n' ' ')
[[ "$ids2" == "f3 o3 " ]] && ok "pairing happens before the window cut (N=2 -> f3 o3)" || bad "pairing before the window cut" "got $ids2"

# Delivery notices (design/outbound_delivery.md, part 4): a failed one is
# admitted, with its status and reason, so the mind learns it did not speak;
# a delivered one is not (it would double every send inside the window).
step d1 delivery "not delivered to slack-...: unknown slack address form" 1 ',"source":"slack-bridge","transport":"slack","status":"failed","reason":"unknown slack address form","trigger_step":"m-0001","to":"slack-..."'
step d2 delivery "delivered to slack-C0BMVH6LM4K" 1 ',"source":"slack-bridge","transport":"slack","status":"delivered","channel":"C0BMVH6LM4K","ts":"1757372480.000001","trigger_step":"m-0002","to":"slack-C0BMVH6LM4K"'
dl=$(stream 40 | jq -c 'select(.type == "delivery")')
if [[ "$(printf '%s\n' "$dl" | jq -r .step_id | tr '\n' ' ')" == "d1 " ]] \
   && [[ "$(printf '%s' "$dl" | jq -r '.status + " " + .reason + " " + .to')" == "failed unknown slack address form slack-..." ]]; then
    ok "a failed delivery is shown with status and reason; a delivered one is not"
else
    bad "failed delivery shown, delivered hidden" "$dl"
fi

# An idle run's final repeats its idle step; the final is dropped and a string
# of idle runs collapses to one line (design/outbound_delivery.md).
: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(ts 9999)" >> "$TRAJ"
step w1 thought "some work" 60
for k in 1 2 3; do
    step "ii$k" idle  "idle"                       $((50 - k*10)) ",\"run_id\":\"run-idle-$k\""
    step "if$k" final "Idle — nothing worth doing" $((50 - k*10)) ",\"run_id\":\"run-idle-$k\""
done
step w2 observation "real result" 5 ',"run_id":"run-w2"'
step wf final "run w2 done" 5 ',"run_id":"run-w2"'
ids=$(stream 20 | jq -r .step_id | tr '\n' ' ')
[[ "$ids" == "w1 ii3 wf " ]] && ok "three idle runs collapse to one idle line; their finals are dropped; a working run keeps its final" || bad "idle-run finals dropped" "got $ids"
stream 20 | jq -e 'select(.step_id == "ii3") | .collapsed == 3' >/dev/null && ok "the collapsed idle line counts the runs" || bad "idle count" "$(stream 20 | jq -c 'select(.step_id == "ii3")')"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
