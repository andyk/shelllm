#!/usr/bin/env bash
# test_recap_context_upgrade.sh — `recap --context` on pre-existing history
#
# Usage: tests/test_recap_context_upgrade.sh
#
# The original tiered-memory build recorded "now" as the start marker and
# built nothing older, but assembly decomposed the WHOLE history positionally
# and read every block file unconditionally — so the first --context run on
# any agent with prior history died on a missing block, and (because callers
# wrap it in `2>/dev/null || true`) the mind silently lost both the staircase
# and the raw tail. These tests pin the upgrade path: enable on existing
# history, survive, keep the tail, snap the marker, build forward, print the
# staircase in order, and tolerate a corrupt block.
#
# The `llm` CLI is stubbed (canned rollup JSON, calls logged): no network.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

# --- stub llm: every call logged, canned rollup JSON back -------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/llm" <<'EOF'
#!/usr/bin/env bash
input=$(cat)
printf 'CALL\n%s\n---\n' "$input" >> "$LLM_LOG"
n=$(printf '%s' "$input" | wc -l | tr -d ' ')
printf '{"summary":"rollup of %s lines","themes":["testing"],"step_ids":["st000001"]}' "$n"
EOF
chmod +x "$WORK/bin/llm"
export PATH="$WORK/bin:$REPO/bin:$PATH"
export LLM_LOG="$WORK/llm.log"
unset TRAJ_DIR TRAJ_ID RECAP_MODEL SHELLM_FAST_MODEL SHELLM_MODEL 2>/dev/null || true

TRAJ_ROOT="$WORK/trajectories"

mk_traj() { # mk_traj <run-name> <n-signal-steps>
    local run="$TRAJ_ROOT/$1" i
    mkdir -p "$run"
    printf '{"type":"trajectory","step_id":"%s-0000-4000-8000-000000000000","ts":"t0"}\n' \
        "${1%%-*}" > "$run/trajectory.jsonl"
    for (( i = 1; i <= $2; i++ )); do
        printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"thinking about topic %d"}\n' \
            "$i" $((i % 60)) "$i" >> "$run/trajectory.jsonl"
    done
}

blockfile() { # blockfile <run-name> <tier> <s> <e>
    printf '%s/%s/rollups/t%s/%012d-%012d.json' "$TRAJ_ROOT" "$1" "$2" "$3" "$4"
}

mk_block() { # mk_block <run-name> <tier> <s> <e> <summary>
    local f
    f=$(blockfile "$1" "$2" "$3" "$4")
    mkdir -p "$(dirname "$f")"
    jq -n -c --argjson tier "$2" --argjson start "$3" --argjson stop "$4" --arg sum "$5" \
        '{tier:$tier, start:$start, end:$stop, n:($stop-$start), summary:$sum, step_ids:["x1","x2"]}' > "$f"
}

# ---------------------------------------------------------------------------
# 1. Upgrade path: 63 steps of prior history, first --context enable.
#    Nothing is built (forward-only), cut0=50 references five unbuilt tier-1
#    blocks — must NOT die, must print the tail, must call no llm.
# ---------------------------------------------------------------------------
mk_traj cafe1111-root 63
out=$(recap cafe1111 --traj_dir "$TRAJ_ROOT" --context --raw-tail 5 2>&1)
rc=$?
check "upgrade: exits 0"                 test "$rc" -eq 0
check "upgrade: raw tail present"        grep -q 'RIGHT NOW' <<<"$out"
check "upgrade: newest step in tail"     grep -q 'topic 63' <<<"$out"
check_not "upgrade: no summary header"   grep -q 'YOUR LIFE SO FAR' <<<"$out"
check "upgrade: no llm calls"            test ! -s "$LLM_LOG"

META="$TRAJ_ROOT/cafe1111-root/rollups/meta.json"
check "upgrade: meta written"            test -f "$META"
check "upgrade: start snapped 63→60"     test "$(jq -r .start_index "$META")" = "60"

# ---------------------------------------------------------------------------
# 2. Going forward: history grows past the marker; the frontier block seals
#    (one llm call) and the staircase appears — older unbuilt region skipped.
# ---------------------------------------------------------------------------
for (( i = 64; i <= 75; i++ )); do
    printf '{"type":"thought","step_id":"st%06d","ts":"2026-07-17T10:%02d:00","source":"tester","content":"thinking about topic %d"}\n' \
        "$i" $((i % 60)) "$i" >> "$TRAJ_ROOT/cafe1111-root/trajectory.jsonl"
done
: > "$LLM_LOG"
out=$(recap cafe1111 --traj_dir "$TRAJ_ROOT" --context --raw-tail 5 2>&1)
rc=$?
check "forward: exits 0"                 test "$rc" -eq 0
check "forward: block [60,70) sealed"    test -f "$(blockfile cafe1111-root 1 60 70)"
check "forward: llm was called"          test -s "$LLM_LOG"
check "forward: summary header appears"  grep -q 'YOUR LIFE SO FAR' <<<"$out"
check "forward: rollup line shown"       grep -q 'rollup of' <<<"$out"
check "forward: newest step in tail"     grep -q 'topic 75' <<<"$out"

# ---------------------------------------------------------------------------
# 3. Staircase order: fabricated blocks t2[0,100), t1[100,110), t1[110,120)
#    must print coarse first and, within a tier, oldest first. (The original
#    flat reverse printed t1[110,120) before t1[100,110).)
# ---------------------------------------------------------------------------
mk_traj beef2222-root 125
mkdir -p "$TRAJ_ROOT/beef2222-root/rollups"
printf '{"start_index":0,"updated":"t"}\n' > "$TRAJ_ROOT/beef2222-root/rollups/meta.json"
mk_block beef2222-root 2 0 100    "SUMMARY-ALPHA oldest hundred"
mk_block beef2222-root 1 100 110  "SUMMARY-BRAVO middle ten"
mk_block beef2222-root 1 110 120  "SUMMARY-CHARLIE newest ten"
out=$(recap beef2222 --traj_dir "$TRAJ_ROOT" --context --cached --raw-tail 5 2>&1)
rc=$?
check "order: exits 0"        test "$rc" -eq 0
seq_found=$(grep -o 'SUMMARY-[A-Z]*' <<<"$out" | tr '\n' ' ')
check "order: coarse→fine, oldest first within tier" \
    test "$seq_found" = "SUMMARY-ALPHA SUMMARY-BRAVO SUMMARY-CHARLIE "

# ---------------------------------------------------------------------------
# 4. Corrupt block: placeholder line, no death, tail intact.
# ---------------------------------------------------------------------------
printf 'not json at all' > "$(blockfile beef2222-root 1 110 120)"
out=$(recap beef2222 --traj_dir "$TRAJ_ROOT" --context --cached --raw-tail 5 2>&1)
rc=$?
check "corrupt: exits 0"                 test "$rc" -eq 0
check "corrupt: placeholder shown"       grep -q 'unreadable rollup block' <<<"$out"
check "corrupt: good blocks still shown" grep -q 'SUMMARY-BRAVO' <<<"$out"
check "corrupt: tail intact"             grep -q 'topic 125' <<<"$out"

# ---------------------------------------------------------------------------
# 5. Boundary crossing: when cut0 crosses a FANOUT^k boundary, the coarse
#    block straddling the enable point (t2[0,100) here, enable at 60) can
#    never seal — assembly must descend into its EXISTING finer children
#    (t1[60,70)..[90,100)) instead of silently dropping all of them.
# ---------------------------------------------------------------------------
mk_traj feed3333-root 215
mkdir -p "$TRAJ_ROOT/feed3333-root/rollups"
printf '{"start_index":60,"updated":"t"}\n' > "$TRAJ_ROOT/feed3333-root/rollups/meta.json"
for s in 60 70 80 90; do
    mk_block feed3333-root 1 "$s" $((s+10)) "T1-FROM-$s"
done
mk_block feed3333-root 2 100 200 "T2-MIDDLE"
mk_block feed3333-root 1 200 210 "T1-NEWEST"
out=$(recap feed3333 --traj_dir "$TRAJ_ROOT" --context --cached --raw-tail 5 2>&1)
rc=$?
check "boundary: exits 0"                     test "$rc" -eq 0
check "boundary: straddled t2 descends to t1" grep -q 'T1-FROM-60' <<<"$out"
check "boundary: all four children shown" \
    test "$(grep -c 'T1-FROM-' <<<"$out")" = "4"
seq_found=$(grep -o 'T[12]-[A-Z0-9-]*' <<<"$out" | tr '\n' ' ')
check "boundary: chronological order" \
    test "$seq_found" = "T1-FROM-60 T1-FROM-70 T1-FROM-80 T1-FROM-90 T2-MIDDLE T1-NEWEST "
check "boundary: tail intact"                 grep -q 'topic 215' <<<"$out"

# ---------------------------------------------------------------------------
# 6. Multiple segments at the TOP tier: the max_tier scan's final comparison
#    is false here (three t2 blocks, no coarser tier) — the staircase and
#    the raw tail must both survive under recap's set -e.
# ---------------------------------------------------------------------------
mk_traj face4444-root 305
mkdir -p "$TRAJ_ROOT/face4444-root/rollups"
printf '{"start_index":0,"updated":"t"}\n' > "$TRAJ_ROOT/face4444-root/rollups/meta.json"
for s in 0 100 200; do
    mk_block face4444-root 2 "$s" $((s+100)) "TOPTIER-$s"
done
out=$(recap face4444 --traj_dir "$TRAJ_ROOT" --context --cached --raw-tail 5 2>&1)
rc=$?
check "top-tier: exits 0"           test "$rc" -eq 0
check "top-tier: all three shown"   test "$(grep -c 'TOPTIER-' <<<"$out")" = "3"
check "top-tier: tail intact"       grep -q 'topic 305' <<<"$out"

# ---------------------------------------------------------------------------
# 7. Flag validation: garbage --raw-tail / --budget must die loudly on the
#    modes that read them, and NOT break plain recap (env-seeded values).
# ---------------------------------------------------------------------------
# Plain recap with garbage context env must get past validation and fail
# (if at all) on its own terms — here, the missing episode cache.
out=$(env MONOLITH_CONTEXT_BUDGET=garbage ROLLUP_RAW_TAIL=nope \
        recap cafe1111 --traj_dir "$TRAJ_ROOT" --cached 2>&1) || true
check "bad env budget ignored off --context" grep -q 'no recap yet' <<<"$out"
check_not "validate: --raw-tail oops rejected" \
    recap cafe1111 --traj_dir "$TRAJ_ROOT" --context --raw-tail oops
check_not "validate: --budget garbage rejected" \
    recap cafe1111 --traj_dir "$TRAJ_ROOT" --context --budget nope

printf '\n%d passed, %d failed\n' "$pass" "$fail"
exit $((fail > 0))
