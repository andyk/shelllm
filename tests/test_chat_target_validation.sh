#!/usr/bin/env bash
# tests/test_chat_target_validation.sh — `chat` refuses a Slack target the
# bridge cannot deliver (design/outbound_delivery.md, part 2).
#
# Usage: tests/test_chat_target_validation.sh
#
# Builds a throwaway trajectory by hand, then checks: the four short and long
# Slack forms are accepted by send, reply, send-file, and react; a malformed
# slack-* name is rejected with a non-zero exit, the accepted forms in the
# error, and no message step written; names for other transports pass through
# untouched. No LLM calls, no docker.

set -uo pipefail
unset IDENTITY_DIR IDENTITY_NAME MEM_DIR TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

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
TRAJ_ID="cafe0000-0000-0000-0000-0000000000ce"
mkdir -p "$ID/trajectories/$TRAJ_ID"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"
printf '{"step_id":"%s","type":"trajectory","ts":"2026-01-01T00:00:00.000Z"}\n' "$TRAJ_ID" > "$TRAJ"
export IDENTITY_NAME="$ME" TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf 'default_send_from=%s\n' "$ME" > "$WORK/home/.chatrc"
export CHATRC="$WORK/home/.chatrc"
printf 'hello\n' > "$WORK/note.txt"

messages() { grep -c '"type":"message"' "$TRAJ"; }

# --- accepted forms ------------------------------------------------------------
for name in slack-U0BFD9NDVE3-C0BMVH6LM4K-1787508187.726149 \
            slack-U0BFD9NDVE3-D0BNW58GP5W \
            slack-C0BMVH6LM4K \
            slack-U0BFD9NDVE3; do
    before=$(messages)
    if chat send --to "$name" "hi" 2>/dev/null && [[ $(messages) -eq $((before + 1)) ]]; then
        ok "send accepts $name"
    else
        bad "send accepts $name"
    fi
done
before=$(messages)
chat reply slack-C0BMVH6LM4K "hi" >/dev/null 2>&1 && [[ $(messages) -eq $((before + 1)) ]] \
    && ok "reply accepts a bare channel" || bad "reply accepts a bare channel"
before=$(messages)
chat send-file --to slack-U0BFD9NDVE3 "$WORK/note.txt" >/dev/null 2>&1 && [[ $(messages) -eq $((before + 1)) ]] \
    && ok "send-file accepts a bare user" || bad "send-file accepts a bare user"
before=$(messages)
chat react slack-U0BFD9NDVE3-C0BMVH6LM4K-1787508187.726149 thumbsup >/dev/null 2>&1 && [[ $(messages) -eq $((before + 1)) ]] \
    && ok "react accepts a thread name" || bad "react accepts a thread name"

# --- other transports are not our business -------------------------------------
before=$(messages)
chat send --to telegram-8525624593-8525624593 "hi" >/dev/null 2>&1 && [[ $(messages) -eq $((before + 1)) ]] \
    && ok "telegram name passes through" || bad "telegram name passes through"
before=$(messages)
chat send --to pwa-andy "hi" >/dev/null 2>&1 && [[ $(messages) -eq $((before + 1)) ]] \
    && ok "pwa name passes through" || bad "pwa name passes through"

# --- malformed slack names are refused -----------------------------------------
for name in slack-nick slack-... slack-c0bmvh6lm4k slack--C0BMVH6LM4K slack-U1-C2-3.4-extra "slack-"; do
    before=$(messages)
    err=$(chat send --to "$name" "hi" 2>&1 >/dev/null); rc=$?
    if [[ $rc -ne 0 && $(messages) -eq $before ]]; then
        ok "send refuses $name (rc=$rc)"
    else
        bad "send refuses $name" "rc=$rc messages=$(messages) before=$before"
    fi
done
err=$(chat send --to slack-nick "hi" 2>&1 >/dev/null)
printf '%s' "$err" | grep -q 'slack-C<id>' && printf '%s' "$err" | grep -q 'slack-U<id>' \
    && ok "error lists the accepted forms" || bad "error lists the accepted forms" "$err"
before=$(messages)
chat reply slack-nick "hi" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && $(messages) -eq $before ]] && ok "reply refuses a malformed name" || bad "reply refuses a malformed name"
before=$(messages)
chat send-file --to slack-nick "$WORK/note.txt" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && $(messages) -eq $before ]] && ok "send-file refuses a malformed name" || bad "send-file refuses a malformed name"
before=$(messages)
chat react slack-nick thumbsup >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 && $(messages) -eq $before ]] && ok "react refuses a malformed name" || bad "react refuses a malformed name"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
