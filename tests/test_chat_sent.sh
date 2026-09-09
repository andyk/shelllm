#!/usr/bin/env bash
# tests/test_chat_sent.sh — `chat sent`, the deliveries index behind it, and
# the repeat refusal in `chat send` / `chat reply` (design/outbound_delivery.md,
# parts 5 and 6).
#
# Usage: tests/test_chat_sent.sh
#
# Builds a trajectory by hand with outbound messages and the `delivery` steps
# a bridge writes back, then checks: each send shows the newest notice's
# state (delivered, failed with reason, skipped), a Slack/Telegram send with
# no notice is pending with an age, a phone-chat send is unconfirmed, inbound
# messages and old sends are excluded by --since, -n and --json work, the
# index picks up notices appended later, and an identical message to the same
# destination inside the window is refused unless --force, while a reply that
# answers a specific inbound is exempt. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID CHAT_REPEAT_WINDOW 2>/dev/null

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

ME=ada
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000cf"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
DLV="$ID/trajectories/$TRAJ_ID/deliveries.jsonl"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$WORK/home/.chatrc"
export CHATRC="$WORK/home/.chatrc"

ago() {  # ISO timestamp N seconds ago
    date -u -v-"$1"S +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "$1 seconds ago" +%Y-%m-%dT%H:%M:%S.000Z
}
msg() {  # msg <id> <from> <to> <content> <secs-ago>
    printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' \
        "$1" "$2" "$3" "$4" "$(ago "$5")" >> "$TRAJ"
}
dlv() {  # dlv <id> <trigger> <status> <secs-ago> [extra json]
    printf '{"step_id":"%s","type":"delivery","source":"slack-bridge","transport":"slack","trigger_step":"%s","status":"%s","ts":"%s"%s}\n' \
        "$1" "$2" "$3" "$(ago "$4")" "${5:-}" >> "$TRAJ"
}

printf '{"step_id":"%s","type":"trajectory","ts":"%s"}\n' "$TRAJ_ID" "$(ago 999999)" > "$TRAJ"
msg m0 "$ME" slack-C0BMVH6LM4K "two days ago"       $((2*86400))
dlv  d0 m0 delivered $((2*86400-5))
msg m1 "$ME" slack-C0BMVH6LM4K "papers for today"   7200
dlv  d1 m1 delivered 7195 ',"channel":"C0BMVH6LM4K","permalink":"https://x.slack.com/archives/C0BMVH6LM4K/p1"'
msg m2 "$ME" slack-... "lost papers"                 5400
dlv  d2 m2 failed 5399 ',"reason":"unknown slack address form"'
msg m3 "$ME" slack-U0BFD9NDVE3 "no bridge answer yet" 3600
msg m4 "$ME" pwa-andy "phone note"                    1800
msg in1 slack-U095QV3JKA6-D0BNW58GP5X "$ME" "inbound, not ours" 900   # another person: must not count as an unanswered question from THEM below
msg m5 "$ME" telegram-1-1 "tg note"                   600
dlv  d5a m5 failed 599 ',"reason":"first try"'
dlv  d5b m5 delivered 598

out=$(chat sent --since 24h)
lines=$(printf '%s\n' "$out" | grep -c .)
[[ "$lines" -eq 5 ]] && ok "--since 24h lists the 5 sends inside the window" || bad "--since 24h count" "got $lines: $out"
printf '%s\n' "$out" | head -1 | grep -q 'telegram-1-1  delivered' && ok "newest first; the newest notice per send wins (failed then delivered)" || bad "newest notice wins" "$(printf '%s\n' "$out" | head -1)"
printf '%s\n' "$out" | grep -q 'slack-\.\.\.  failed (unknown slack address form)  lost papers' && ok "a failed send shows its reason" || bad "failed reason shown" "$out"
printf '%s\n' "$out" | grep -qE 'slack-U0BFD9NDVE3  pending (59m|1h)  no bridge answer yet' && ok "a Slack send with no notice is pending with its age" || bad "pending with age" "$out"
printf '%s\n' "$out" | grep -q 'pwa-andy  unconfirmed  phone note' && ok "a phone-chat send is unconfirmed (no bridge writes notices)" || bad "unconfirmed" "$out"
msg m6 "$ME" telegram-2-2 "tg no notice" 300
chat sent --since 24h | grep -q 'telegram-2-2  unconfirmed  tg no notice' && ok "a Telegram send with no notice is unconfirmed, not pending" || bad "telegram unconfirmed" "$(chat sent --since 24h | head -3)"
printf '%s\n' "$out" | grep -q 'inbound, not ours' && bad "inbound messages are excluded" || ok "inbound messages are excluded"
printf '%s\n' "$out" | grep -q 'two days ago' && bad "--since excludes old sends" || ok "--since excludes old sends"
[[ "$(chat sent | grep -c .)" -eq 7 ]] && ok "without --since every send is listed" || bad "no --since lists all" "$(chat sent)"
[[ "$(chat sent -n 2 | grep -c .)" -eq 2 ]] && ok "-n bounds the list" || bad "-n bounds"
j=$(chat sent --since 24h --json)
[[ "$(printf '%s' "$j" | jq -r '.[] | select(.step_id=="m1") | .state + " " + .permalink')" == "delivered https://x.slack.com/archives/C0BMVH6LM4K/p1" ]] \
    && ok "--json carries state and permalink" || bad "--json fields" "$j"
[[ "$(printf '%s' "$j" | jq -r '.[] | select(.step_id=="m3") | .age_s >= 3500')" == "true" ]] && ok "--json carries age_s" || bad "--json age_s"
[[ -f "$DLV" && "$(grep -c . "$DLV")" -eq 5 ]] && ok "deliveries.jsonl holds every notice" || bad "deliveries index" "$(cat "$DLV" 2>/dev/null)"

# A notice appended later is picked up without a rebuild.
dlv d3 m3 delivered 5 ',"channel":"D1"'
chat sent --since 24h | grep -q 'slack-U0BFD9NDVE3  delivered' && ok "a notice appended later updates the state" || bad "late notice picked up" "$(chat sent --since 24h)"

# --- repeat refusal ---------------------------------------------------------
before=$(grep -c '"type":"message"' "$TRAJ")
chat send --to slack-C0BMVH6LM4K "brand new text" >/dev/null 2>&1 && ok "a new message sends" || bad "new message sends"
err=$(chat send --to slack-C0BMVH6LM4K "brand new text" 2>&1 >/dev/null); rc=$?
[[ $rc -ne 0 && $(grep -c '"type":"message"' "$TRAJ") -eq $((before + 1)) ]] && ok "the same text to the same destination is refused (rc=$rc)" || bad "repeat refused" "rc=$rc"
printf '%s' "$err" | grep -q 'already went to' && printf '%s' "$err" | grep -q -- '--force' && ok "the refusal names the earlier send and --force" || bad "refusal text" "$err"
chat send --to slack-C0BMVH6LM4K --force "brand new text" >/dev/null 2>&1 && ok "--force sends it again" || bad "--force sends"
chat send --to slack-U0BFD9NDVE3 "brand new text" >/dev/null 2>&1 && ok "the same text to another destination is fine" || bad "other destination"
CHAT_REPEAT_WINDOW=0 chat send --to slack-C0BMVH6LM4K "brand new text" >/dev/null 2>&1 && ok "CHAT_REPEAT_WINDOW=0 disables the check" || bad "window 0 disables"
# An old identical send (outside the window) does not block.
chat send --to slack-C0BMVH6LM4K "two days ago" >/dev/null 2>&1 && ok "an identical send outside the window does not block" || bad "old send does not block"

# reply: answering a specific inbound is exempt; a proactive reply is checked.
THEM=slack-U0BFD9NDVE3-D0BNW58GP5W
msg in2 "$THEM" "$ME" "status?" 30
chat reply "$THEM" "still running" >/dev/null 2>&1 && ok "reply answers in2" || bad "reply answers in2"
msg in3 "$THEM" "$ME" "status??" 20
# --reply-to given explicitly: the inference path needs `timeout`, which a
# stock Mac lacks, and the exemption is about the stamp, not how it got there.
chat reply --reply-to in3 "$THEM" "still running" >/dev/null 2>&1 && ok "the same answer to a second question is allowed" || bad "answer exempt"
# Every inbound from THEM is now answered, so the next reply answers nothing
# whether inference runs (CI, the box) or not (a Mac without `timeout`).
before=$(grep -c '"type":"message"' "$TRAJ")
chat reply "$THEM" "still running" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && $(grep -c '"type":"message"' "$TRAJ") -eq $before ]] && ok "a proactive reply (nothing left to answer) with the same text is refused" || bad "proactive reply refused" "rc=$rc"
chat reply --force "$THEM" "still running" >/dev/null 2>&1 && ok "--force lets the proactive repeat through" || bad "reply --force"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
