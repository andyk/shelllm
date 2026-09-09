#!/usr/bin/env bash
# tests/test_responder_metrics.sh — the context metrics the responder stamps on
# its decision observation (design/conversation_memory.md, part 6).
#
# Usage: tests/test_responder_metrics.sh
#
# Drives thinkers/responder/step against a throwaway identity with a stubbed
# `llm` on PATH (replies with a fixed line, or NO_REPLY). Real traj + chat from
# bin/. No LLM calls, no docker. The observable output is the observation the
# step appends: it must carry context_msgs, context_steps, gap_s, compose_ms
# and model, and context_msgs must say what the responder actually had —
# including 0 when the window has already forgotten the conversation, which
# is the case the metric exists to count.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID THINK_CONTEXT_TAIL 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
STEP="$REPO/thinkers/responder/step"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

ME=testid
THEM=nick
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ab"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

# --- llm stub -----------------------------------------------------------------
mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_REPLY_FILE"
STUB
chmod +x "$WORK/stub/llm"
export STUB_REPLY_FILE="$WORK/reply"

# ISO timestamps N seconds ago, in traj's own format (UTC, millis, Z).
ago() {
    date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z
}
# N seconds in the future: later triggers sit strictly after the reply the
# step just wrote, so gap_s has an unambiguous "previous message" even when
# two cases run inside the same second.
ahead() {
    date -u -v+"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 seconds" +%Y-%m-%dT%H:%M:%S.000Z
}
msg() {  # msg <id> <from> <to> <content> <secs-ago|+secs-ahead>
    local ts
    case "$5" in +*) ts=$(ahead "${5#+}") ;; *) ts=$(ago "$5") ;; esac
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' \
        "$1" "$2" "$3" "$4" "$ts" >> "$TRAJ"
}
thoughts() {  # thoughts <count> <prefix>
    local i
    for ((i=1; i<=$1; i++)); do
        printf '{"step_id":"%s-%d","type":"thought","content":"musing %d","ts":"%s","source":"monolith"}\n' \
            "$2" "$i" "$i" "$(ago 10)" >> "$TRAJ"
    done
}

run_step() {  # $1 = trigger json
    printf '%s' "$1" | env \
        PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        SHELLM_MODEL="stub-model" THINK_CONTEXT_TAIL=20 \
        RESPONDER_LOG_PROMPT="${LOG_PROMPT:-0}" RESPONDER_PERSON_NOTES=0 \
        "$STEP" >> "$WORK/step.log" 2>&1
}
trigger_json() {  # trigger_json <id> — the trigger step as the dispatcher delivers it
    grep -F "\"step_id\":\"$1\"" "$TRAJ" | head -1
}
obs_for() {  # obs_for <trigger id> — the responder's decision observation
    jq -c --arg t "$1" 'select(.type == "observation" and .source == "responder"
                              and (.trigger_step // "") == $t and (.decision // "") != "")' "$TRAJ" | tail -1
}
field() { printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty'; }

# --- 1. an active conversation: the metrics say what was in the prompt ------
: > "$TRAJ"
msg m-old  "$THEM" "$ME"   "how is the bridge work going"  3600
msg r-old  "$ME"   "$THEM" "about half done"               3500
thoughts 5 th
msg trig-1 "$THEM" "$ME"   "any update"                    0
printf 'still about half done\n' > "$STUB_REPLY_FILE"
LOG_PROMPT=1 run_step "$(trigger_json trig-1)"

obs=$(obs_for trig-1)
if [[ -n "$obs" && "$(field "$obs" decision)" == replied ]]; then
    ok "replied observation written"
else
    bad "replied observation written" "$(tail -3 "$WORK/step.log")"
fi
if jq -s -e --arg t trig-1 'any(.[]; .type=="message" and .from=="testid" and .reply_to==$t)' "$TRAJ" >/dev/null; then
    ok "reply stamped to the trigger"
else
    bad "reply stamped to the trigger"
fi
[[ "$(field "$obs" context_msgs)" == 2 ]] \
    && ok "context_msgs counts the two earlier messages, not the trigger" \
    || bad "context_msgs counts the two earlier messages, not the trigger" "got '$(field "$obs" context_msgs)'"
steps=$(printf '%s' "$obs" | jq -c '.context_steps')
if printf '%s' "$steps" | jq -e 'index("m-old") and index("r-old") and index("trig-1") and index("th-5")' >/dev/null 2>&1; then
    ok "context_steps lists the conversation and the inner-life steps"
else
    bad "context_steps lists the conversation and the inner-life steps" "got $steps"
fi
gap=$(field "$obs" gap_s)
if [[ "$gap" =~ ^[0-9]+$ ]] && (( gap >= 3495 && gap <= 3510 )); then
    ok "gap_s is the time since the previous message with this person"
else
    bad "gap_s is the time since the previous message with this person" "got '$gap'"
fi
ms=$(field "$obs" compose_ms)
[[ "$ms" =~ ^[0-9]+$ ]] && ok "compose_ms is a number" || bad "compose_ms is a number" "got '$ms'"
[[ "$(field "$obs" model)" == stub-model ]] && ok "model recorded" || bad "model recorded" "got '$(field "$obs" model)'"
[[ "$(field "$obs" history_source)" == index ]] && ok "history came from the message index" || bad "history came from the message index" "got '$(field "$obs" history_source)'"
if grep -q '\[60 min ago\] how is the bridge work going' "$ID/run/logs/responder-prompts/"*trig-1* 2>/dev/null \
   && grep -q 'The current time is 20' "$ID/run/logs/responder-prompts/"*trig-1* 2>/dev/null; then
    ok "their messages carry an age stamp and the prompt states the current time"
else
    bad "their messages carry an age stamp and the prompt states the current time" "$(grep -o '\[[^]]*ago\]' "$ID/run/logs/responder-prompts/"*trig-1* 2>/dev/null | head -2 | tr '\n' ' ')"
fi

# --- 2. beyond the history window: context_msgs is 0 but gap_s still knows ---
# Parts 1+2 read this person's messages over the last 7 days from the index, so
# mind activity no longer evicts a conversation. Only age does: a sender whose
# whole exchange is 8 days old gets an empty history, while gap_s (raw tail)
# still reports the real gap.
msg o-old  "oldfriend" "$ME"   "remember me?"   $((8*86400))
msg o-rep  "$ME"   "oldfriend" "of course"      $((8*86400-60))
thoughts 40 pad
msg trig-2 "oldfriend" "$ME" "sure!" +5
printf 'sure what?\n' > "$STUB_REPLY_FILE"
run_step "$(trigger_json trig-2)"
obs=$(obs_for trig-2)
[[ "$(field "$obs" context_msgs)" == 0 ]] \
    && ok "a conversation older than the history window is recorded as context_msgs 0" \
    || bad "a conversation older than the history window is recorded as context_msgs 0" "got '$(field "$obs" context_msgs)'"
gap=$(field "$obs" gap_s)
if [[ "$gap" =~ ^[0-9]+$ ]] && (( gap >= 8*86400-120 && gap <= 8*86400+60 )); then
    ok "gap_s measured from the raw tail, not the history"
else
    bad "gap_s measured from the raw tail, not the history" "got '$gap'"
fi
if printf '%s' "$obs" | jq -e '.context_steps | index("o-old") == null and index("trig-2")' >/dev/null 2>&1; then
    ok "context_steps reflects the empty history"
else
    bad "context_steps reflects the empty history" "got $(printf '%s' "$obs" | jq -c .context_steps)"
fi
# and the case the whole plan is for: 40 thoughts between messages no longer
# makes the responder forget nick
msg trig-2b "$THEM" "$ME" "still there?" +6
printf 'yes\n' > "$STUB_REPLY_FILE"
run_step "$(trigger_json trig-2b)"
obs=$(obs_for trig-2b)
[[ "$(field "$obs" context_msgs)" -ge 4 ]] \
    && ok "mind activity no longer evicts the conversation (context_msgs $(field "$obs" context_msgs) after 40 thoughts)" \
    || bad "mind activity no longer evicts the conversation" "got '$(field "$obs" context_msgs)'"

# --- 3. NO_REPLY carries the same metrics -------------------------------------
msg trig-3 "$THEM" "$ME" "thanks" +10
printf 'NO_REPLY\n' > "$STUB_REPLY_FILE"
run_step "$(trigger_json trig-3)"
obs=$(obs_for trig-3)
if [[ "$(field "$obs" decision)" == no-reply && "$(field "$obs" context_msgs)" =~ ^[0-9]+$ \
      && "$(field "$obs" compose_ms)" =~ ^[0-9]+$ && "$(field "$obs" model)" == stub-model ]]; then
    ok "no-reply observation carries the metrics"
else
    bad "no-reply observation carries the metrics" "got $obs"
fi

# --- 4. first contact: no gap_s, everything else present ----------------------
msg trig-4 "stranger" "$ME" "hello there" +15
printf 'hi\n' > "$STUB_REPLY_FILE"
run_step "$(trigger_json trig-4)"
obs=$(obs_for trig-4)
if [[ -n "$obs" && -z "$(field "$obs" gap_s)" && "$(field "$obs" context_msgs)" == 0 ]]; then
    ok "first contact: no gap_s, context_msgs 0"
else
    bad "first contact: no gap_s, context_msgs 0" "got $obs"
fi

# --- 5. RESPONDER_LOG_PROMPT writes to run/logs, not the trajectory -----------
msg trig-5 "$THEM" "$ME" "one more" +20
printf 'ok\n' > "$STUB_REPLY_FILE"
LOG_PROMPT=1 run_step "$(trigger_json trig-5)"
plog=0
for f in "$ID/run/logs/responder-prompts/"*trig-5*; do [[ -f "$f" ]] && plog=$((plog+1)); done
[[ "$plog" == 1 ]] && ok "prompt log file written under run/logs" || bad "prompt log file written under run/logs" "found $plog"
if grep -q '# system' "$ID/run/logs/responder-prompts/"*trig-5* 2>/dev/null \
   && ! grep -q 'live chat conversation' "$TRAJ"; then
    ok "prompt text is in the log file and not in the trajectory"
else
    bad "prompt text is in the log file and not in the trajectory"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
