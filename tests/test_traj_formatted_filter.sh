#!/usr/bin/env bash
# tests/test_traj_formatted_filter.sh — `traj tail --filter` and `traj cat
# --filter` work in formatted mode, which is what a terminal gets.
#
# Usage: tests/test_traj_formatted_filter.sh
#
# Why: in formatted mode _format_line hands each step to jq, whose program
# starts with `select(matches_filters($filters))`, and reads the six result
# lines back with a `{ read; read; ... } < <(jq ...)` group. When a step does
# not match, jq emits nothing, the first `read` fails at EOF, and under the
# file's `set -e` that kills the `while read` subshell driving the stream. The
# guard meant to skip a non-matching step, `[[ -n "$entry_type" ]] || return 0`,
# sits right after the group and is never reached. So `traj tail --filter ...`
# at a terminal printed nothing and exited 1 — usually on the very first line,
# the trajectory header, which matches no type filter. The same failing read
# also cut an unfiltered formatted stream off at the first malformed line.
#
# The -a branch of the same function already does it right: capture jq's
# output, return on failure or empty, then split. And since #110, the -r path
# pre-filters in _sorted_tree_steps, so `traj cat -r --filter` worked while
# `traj cat --filter` did not. Raw mode filters correctly, so the oracle for
# "which steps should a filter select" is the raw stream itself.

set -uo pipefail
unset TRAJ_DIR TRAJ_ID ROOT_TRAJ_ID 2>/dev/null

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
export PATH="$REPO/bin:$PATH"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
is()  { # is LABEL EXPECTED ACTUAL
    if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FAIL jq not found"; exit 1; }

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

export TRAJ_DIR="$WORK/trajectories"
mkdir -p "$TRAJ_DIR"
TRAJ_ID=$(traj new --slug root | head -1)
export TRAJ_ID
traj append --field type=thought --field content=T1 >/dev/null
traj append --field type=action  --field content=A1 >/dev/null
traj append --field type=thought --field content=T2 >/dev/null
traj append --field type=message --field content=M1 --field source=nick >/dev/null
FILE=$(traj path)
[[ -f "$FILE" ]] || { echo "FAIL could not build the trajectory"; exit 1; }

# A formatted line is "date time step_id [type] content" (--no-color), so the
# last field is the content and the third is the 8-hex step id.
contents() { awk '{print $NF}' | tr '\n' ' ' | sed 's/ $//'; }
lines()    { grep -c . ; }

# --- the everyday command: a type filter at a terminal ------------------------
out=$(traj cat --format --no-color --filter type=thought); rc=$?
is "cat --filter exits 0 in formatted mode"       "0"     "$rc"
is "cat --filter prints the matching steps"        "T1 T2" "$(printf '%s\n' "$out" | contents)"

out=$(traj tail -n 10 --format --no-color --filter type=thought); rc=$?
is "tail --filter exits 0 in formatted mode"      "0"     "$rc"
is "tail --filter prints the matching steps"       "T1 T2" "$(printf '%s\n' "$out" | contents)"

# --- formatted mode selects exactly what raw mode selects ---------------------
want=$(traj cat --raw --filter type=thought | jq -r '.step_id[0:8]' | tr '\n' ' ' | sed 's/ $//')
got=$(traj cat --format --no-color --filter type=thought | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//')
is "formatted and raw modes agree on which steps match" "$want" "$got"

# --- a stream that starts matching and then stops must not die midway --------
# Only the header matches type=trajectory; the step after it is the first
# non-match, which is where the unguarded read used to kill the stream.
# The two line-count checks here pass on main as well, because there the
# stream dies at its first step; they guard against over-printing and lean on
# the exit-code check beside each for the bug itself.
out=$(traj cat --format --no-color --filter type=trajectory); rc=$?
is "a filter only the header matches exits 0"      "0" "$rc"
is "a filter only the header matches prints one line" "1" "$(printf '%s\n' "$out" | lines)"

out=$(traj cat --format --no-color --filter type=nope); rc=$?
is "a filter nothing matches exits 0"              "0" "$rc"
is "a filter nothing matches prints nothing"       "0" "$(printf '%s\n' "$out" | lines)"

# --- the filter grammar still works in formatted mode -------------------------
is "two --filter flags are AND-ed"                 "T2" \
   "$(traj cat --format --no-color --filter type=thought --filter content=T2 | contents)"
is "comma-separated values are OR-ed"              "T1 A1 T2" \
   "$(traj cat --format --no-color --filter type=thought,action | contents)"

# --- the neighbours are unchanged ---------------------------------------------
is "unfiltered formatted output still shows every step" "5" \
   "$(traj cat --format --no-color | lines)"
is "-a --filter still works"                       "T1 T2" \
   "$(traj cat -a --format --no-color --filter type=thought | contents)"
is "raw --filter is untouched"                     "2" \
   "$(traj cat --raw --filter type=thought | lines)"

# --- a formatted line is stamp, id, [type, source], content -------------------
# Pins the correspondence between the six lines jq emits and the six reads that
# consume them, which is exactly what moving the read block could break. The
# stamp is derived from the raw stream, the oracle, so this does not depend on
# the machine's timezone.
sid=$(traj cat --raw --filter content=M1 | jq -r '.step_id[0:8]')
ets=$(traj cat --raw --filter content=M1 | jq -r '.ts' | sed 's/T/ /; s/[.Z].*//; s/-/\//g')
is "a formatted line carries stamp, id, type, source and content" \
   "$ets $sid [message, nick] M1" "$(traj cat --format --no-color --filter content=M1)"
is "the type column is each step's own type" "trajectory thought action thought message" \
   "$(traj cat --format --no-color | sed -n 's/.*\[\([^],]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
hex=$(basename "$(dirname "$FILE")" | cut -d- -f1)
is "-r prefixes the id column with the file hex" "$hex/$sid" \
   "$(traj cat -r --format --no-color --filter content=M1 | awk '{print $3}')"

# --- a malformed line no longer truncates the formatted stream ----------------
# A writer killed mid-append leaves a line jq cannot parse. The steps after it
# are fine and must still be shown, as -a and raw already do.
printf 'this is not json\n' >> "$FILE"
traj append --field type=thought --field content=T3 >/dev/null
out=$(traj cat --format --no-color); rc=$?
is "a malformed line does not end the formatted stream" "0" "$rc"
is "steps after a malformed line are still shown" "6" "$(printf '%s\n' "$out" | lines)"
is "the last step after the malformed line is there" "T3" "$(printf '%s\n' "$out" | tail -1 | contents)"
is "a malformed line produces no stderr noise" "" "$(traj cat --format --no-color 2>&1 >/dev/null)"

# --- a record with an empty trailing field is read, not fatal -----------------
# jq emits the fields one per line and the capture drops trailing newlines, so
# a step whose last field, _traj_hex, is the empty string comes back a line
# short. The process substitution this replaces read it as empty. `traj
# append` accepts any key, so traj itself can write such a step.
traj append --field type=thought --field content=T4 --field _traj_hex= >/dev/null
traj append --field type=thought --field content=T5 >/dev/null
out=$(traj cat --format --no-color); rc=$?
is "an empty trailing field does not end the formatted stream" "0" "$rc"
is "the short record and the steps after it are shown" "T4 T5" "$(printf '%s\n' "$out" | tail -2 | contents)"

# --- a step jq cannot render is skipped, not fabricated and not fatal ----------
# `traj append` takes JSON on stdin and checks only that it parses, so .content
# can be an object. The preview slices it, jq errors after emitting one of its
# six lines, and on main the read group died there, taking the rest of the
# stream with it (-r included, since its pre-filter passes the step). Guarding
# the old read group with `|| true` instead would print a fabricated line with
# a blank stamp and id; capturing first lets `|| return 0` see the failure and
# skip the step.
printf '%s' '{"type":"thought","content":{"plan":["a","b"]}}' | traj append >/dev/null
traj append --field type=thought --field content=T6 >/dev/null
out=$(traj cat --format --no-color); rc=$?
is "a step jq cannot render does not end the formatted stream" "0" "$rc"
is "the step after it is still shown" "T6" "$(printf '%s\n' "$out" | tail -1 | contents)"
is "no fabricated line stands in for it" "0" "$(printf '%s\n' "$out" | grep -c -- '----/--/--')"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
