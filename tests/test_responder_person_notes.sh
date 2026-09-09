#!/usr/bin/env bash
# tests/test_responder_person_notes.sh — per-person notes the responder keeps
# (design/conversation_memory.md, part 4).
#
# Usage: tests/test_responder_person_notes.sh
#
# After a reply the responder rewrites a `type: person` memory for the sender's
# person key on a cheap model and reads it back into its next prompt. Pins:
# the file is created in mem's format with person_key and aliases; a second
# reply updates the same file (no duplicates) and keeps id, created, and
# aliases; the prompt carries a "What you know about" block; the notes prompt
# has the facts-only rules Experiment C asked for; key-shaped strings are
# redacted; RESPONDER_PERSON_NOTES=0 disables it. The writer runs in the
# foreground here (RESPONDER_PERSON_NOTES_SYNC=1). Stubbed llm; no LLM calls.

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
THEM="slack-U0614H65RN3-C0BMVH6LM4K-1787508187.726149"
THEM_DM="slack-U0614H65RN3-D0BNW58GP5W"
ID="$WORK/ident"
TRAJ_ID="cafe0000-0000-0000-0000-0000000000f0"
mkdir -p "$ID/memories" "$ID/trajectories/$TRAJ_ID" "$ID/run"
printf 'name=%s\ncreated=test\nroot_trajectory=%s\n' "$ME" "$TRAJ_ID" > "$ID/info.txt"
TRAJ="$ID/trajectories/$TRAJ_ID/trajectory.jsonl"

# The stub answers the notes call (system prompt mentions "private notes")
# from one file and the reply call from another, and records both prompts.
mkdir -p "$WORK/stub"
cat > "$WORK/stub/llm" <<'STUB'
#!/usr/bin/env bash
sys=""; prev=""
for a in "$@"; do [[ "$prev" == "-s" ]] && sys="$a"; prev="$a"; done
if [[ "$sys" == *"private notes"* ]]; then
    printf '%s\n' "$sys" > "$STUB_NOTES_SYS"
    cat "$STUB_NOTES_FILE"
else
    printf '%s\n' "$sys" > "$STUB_REPLY_SYS"
    cat "$STUB_REPLY_FILE"
fi
STUB
chmod +x "$WORK/stub/llm"
export STUB_REPLY_FILE="$WORK/reply" STUB_NOTES_FILE="$WORK/notes" STUB_NOTES_SYS="$WORK/notes.sys" STUB_REPLY_SYS="$WORK/reply.sys"

run_step() {  # run_step <trigger json> [extra env...]
    local trig="$1"; shift
    printf '%s' "$trig" | env \
        PATH="$WORK/stub:$REPO/bin:$REPO/tools:$PATH" \
        IDENTITY_DIR="$ID" IDENTITY_NAME="$ME" MEM_DIR="$ID/memories" \
        TRAJ_DIR="$ID/trajectories" TRAJ_ID="$TRAJ_ID" HOME="$WORK/home" \
        SHELLM_MODEL=stub-model THINK_CONTEXT_TAIL=20 \
        RESPONDER_PERSON_NOTES_SYNC=1 "$@" \
        "$STEP" >> "$WORK/step.log" 2>&1
}
now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
msg() { printf '{"step_id":"%s","type":"message","from":"%s","to":"%s","content":"%s","ts":"%s","source":"chat"}\n' "$1" "$2" "$3" "$4" "$(now)" >> "$TRAJ"; }
person_files() { grep -l '^type: person' "$ID/memories"/*.md 2>/dev/null | wc -l | tr -d ' '; }

: > "$TRAJ"
printf '{"step_id":"hdr","type":"trajectory","ts":"%s"}\n' "$(now)" >> "$TRAJ"

# --- 1. first reply creates the notes file --------------------------------
msg trig-1 "$THEM" "$ME" "hi, I am Andy, I run the lab. keep replies short please"
printf 'Hi Andy, will do.\n' > "$STUB_REPLY_FILE"
printf 'Andy runs the lab and reaches testid on Slack.\nPrefers short replies (stated 2026-09-02).\nToken sk-abcdefghijklmnopqrstuvwxyz0123 was pasted once.\n' > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-1"' "$TRAJ")"

[[ "$(person_files)" == 1 ]] && ok "a type: person memory is created after the first reply" || bad "a type: person memory is created after the first reply" "found $(person_files); $(tail -3 "$WORK/step.log")"
f=$(grep -l '^type: person' "$ID/memories"/*.md | head -1)
if grep -q '^person_key: slack:U0614H65RN3$' "$f" && grep -q '^aliases: \[\]$' "$f" && grep -q '^id: [0-9a-f]\{8\}$' "$f" && grep -q '^created: ' "$f"; then
    ok "frontmatter has id, person_key, aliases, created in mem's format"
else
    bad "frontmatter has id, person_key, aliases, created" "$(sed -n 1,8p "$f")"
fi
grep -q 'Prefers short replies' "$f" && ok "the notes body is the model's output" || bad "the notes body is the model's output"
if grep -q '\[redacted\]' "$f" && ! grep -q 'sk-abcdefghijklmnop' "$f"; then
    ok "key-shaped strings are redacted before writing"
else
    bad "key-shaped strings are redacted before writing"
fi
case "$(basename "$f")" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]_person-*.md) ok "filename follows mem's timestamp_hex_slug convention" ;;
    *) bad "filename follows mem's timestamp_hex_slug convention" "$(basename "$f")" ;;
esac
if grep -q 'facts and stated' "$STUB_NOTES_SYS" && grep -qi 'never turn one incident into a rule' "$STUB_NOTES_SYS" && grep -q 'do not record refusals' "$STUB_NOTES_SYS"; then
    ok "the notes prompt carries the facts-only rules from Experiment C"
else
    bad "the notes prompt carries the facts-only rules from Experiment C"
fi

# --- 2. the next reply reads the notes and updates the same file ----------
# Add an alias by hand (what part 2's alias merge reads) and check it survives.
sed -i.bak 's/^aliases: \[\]$/aliases: [pwa:andy]/' "$f" && rm -f "$f.bak"
id_before=$(sed -n 's/^id: //p' "$f"); created_before=$(sed -n 's/^created: //p' "$f")
msg trig-2 "$THEM_DM" "$ME" "did you see the new PR?"
printf 'Not yet, looking now.\n' > "$STUB_REPLY_FILE"
printf 'Andy runs the lab and reaches testid on Slack (threads and DMs).\nPrefers short replies (stated 2026-09-02).\nAsked about a new PR on 2026-09-02; open.\n' > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-2"' "$TRAJ")"

if grep -q 'What you know about slack-U0614H65RN3-D0BNW58GP5W' "$STUB_REPLY_SYS" && grep -q 'Prefers short replies' "$STUB_REPLY_SYS"; then
    ok "the reply prompt carries the notes, found via the DM name (same person key)"
else
    bad "the reply prompt carries the notes, found via the DM name" "$(grep -c 'What you know' "$STUB_REPLY_SYS")"
fi
grep -q 'do not treat one past incident as a rule' "$STUB_REPLY_SYS" && ok "the reader block warns against reading notes as rules" || bad "the reader block warns against reading notes as rules"
[[ "$(person_files)" == 1 ]] && ok "the second reply updates the same file, no duplicate" || bad "the second reply updates the same file, no duplicate" "found $(person_files)"
f2=$(grep -l '^type: person' "$ID/memories"/*.md | head -1)
if [[ "$(sed -n 's/^id: //p' "$f2")" == "$id_before" && "$(sed -n 's/^created: //p' "$f2")" == "$created_before" ]] \
   && grep -q '^aliases: \[pwa:andy\]$' "$f2" && grep -q '^updated: ' "$f2" && grep -q 'Asked about a new PR' "$f2"; then
    ok "rewrite keeps id, created, and aliases; adds updated; carries the new body"
else
    bad "rewrite keeps id, created, and aliases; adds updated" "$(sed -n 1,9p "$f2")"
fi

# --- 3. disabled: no notes read or written -------------------------------
rm -f "$ID/memories"/*.md "$STUB_REPLY_SYS"
msg trig-3 "$THEM" "$ME" "ping"
printf 'pong\n' > "$STUB_REPLY_FILE"
run_step "$(grep -F '"step_id":"trig-3"' "$TRAJ")" RESPONDER_PERSON_NOTES=0
if [[ "$(person_files)" == 0 ]] && ! grep -q 'What you know about' "$STUB_REPLY_SYS"; then
    ok "RESPONDER_PERSON_NOTES=0 disables reading and writing"
else
    bad "RESPONDER_PERSON_NOTES=0 disables reading and writing"
fi

# --- 4. a first contact with no history still replies ----------------------
msg trig-4 stranger "$ME" "hello"
printf 'hi\n' > "$STUB_REPLY_FILE"
printf 'Stranger said hello.\n' > "$STUB_NOTES_FILE"
run_step "$(grep -F '"step_id":"trig-4"' "$TRAJ")"
jq -s -e 'any(.[]; .type=="message" and .reply_to=="trig-4")' "$TRAJ" >/dev/null && ok "first contact replies and writes notes without error" || bad "first contact replies"

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
