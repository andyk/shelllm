#!/usr/bin/env bash
# thinkers/_lib/common.sh — Shared helper library for thinkers
# Source this file from thinker step scripts.

# ---------------------------------------------------------------------------
# .env loading
# ---------------------------------------------------------------------------

# Fill in vars from a .env file WITHOUT overriding anything already set: the
# dispatcher's environment (web _ENV_WRAPPER, identity shell, an explicit
# THINK_MODEL=...) always wins, and earlier files beat later ones. Values are
# extracted by actually sourcing the file in a subshell so quoting behaves
# exactly like the loaders in bin/llm and bin/shellm.
_load_env_defaults() {
    local envfile="$1"
    [[ -f "$envfile" ]] || return 1
    local key val
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        [[ -n "${!key+x}" ]] && continue
        # shellcheck disable=SC1090  # sourcing the user's own env file
        val=$(set -a; . "$envfile" >/dev/null 2>&1; printf '%s' "${!key}") || { printf '%s: warning: could not read %s; ignoring it\n' "${0##*/}" "$envfile" >&2; return 0; }
        export "$key=$val"
    done < <(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$envfile")
    return 0
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

_require_env() {
    [[ -n "${IDENTITY_DIR:-}" ]] || { printf 'thinker: error: IDENTITY_DIR not set. Run: identity shell <name>\n' >&2; exit 1; }
    [[ -n "${TRAJ_DIR:-}" ]] || { printf 'thinker: error: TRAJ_DIR not set. Run: identity shell <name>\n' >&2; exit 1; }
    [[ -n "${TRAJ_ID:-}" ]] || { printf 'thinker: error: TRAJ_ID not set. Run: identity shell <name>\n' >&2; exit 1; }
    [[ -n "${MEM_DIR:-}" ]] || { printf 'thinker: error: MEM_DIR not set. Run: identity shell <name>\n' >&2; exit 1; }

    # Resolve identity name if not set
    if [[ -z "${IDENTITY_NAME:-}" ]]; then
        IDENTITY_NAME=$(grep '^name=' "$IDENTITY_DIR/info.txt" 2>/dev/null | cut -d= -f2-) || true
        [[ -z "$IDENTITY_NAME" ]] && IDENTITY_NAME=$(basename "$IDENTITY_DIR")
    fi

    # Defaults
    [[ -z "${SKILLS_DIR:-}" ]] && SKILLS_DIR="$IDENTITY_DIR/skills"
    [[ -z "${SKILLS_KERNEL_DIR:-}" ]] && SKILLS_KERNEL_DIR="$IDENTITY_DIR/kernel"

    # .env fallbacks — step scripts resolve THINK_MODEL/SHELLM_MODEL from
    # their environment BEFORE invoking llm/shellm (which load .env too
    # late to influence the -m flag), so the keys must be filled in here.
    _load_env_defaults "$IDENTITY_DIR/.env" || true
    _load_env_defaults ".env" || true
    # The framework state home, where headlong-init writes the API key and
    # SHELLM_MODEL. Resolved without SHELLM_HOME on purpose, unlike bin/llm and
    # bin/shellm: both launchers export SHELLM_HOME as <identity>/.shellm
    # (bin/thinkers, web control.py), so honouring it here would read the
    # identity directory and never the file holding the key. ~/.shellm stays
    # after it for a pre-rename install.
    _load_env_defaults "${HEADLONG_HOME:-$HOME/.headlong}/.env" || true
    _load_env_defaults "$HOME/.shellm/.env" || true

    mkdir -p "$MEM_DIR" "$SKILLS_DIR" "$SKILLS_KERNEL_DIR" "$TRAJ_DIR"
}

# ---------------------------------------------------------------------------
# System prompt assembly
# ---------------------------------------------------------------------------

# One section of the wake prompt, built by a command. Prints the command's
# output; on failure prints nothing, returns nonzero, and makes the failure
# LOUD: a line on stderr (the journal) and an `error` step in the root
# trajectory, at most one per section per hour so a persistent failure does
# not flood the stream. The old form, `$(skills prompt 2>/dev/null) || ""`,
# hid a broken `skills prompt` for 20 days (2026-08-15 to 09-04): every wake
# prompt lost its kernel skills and nothing anywhere said so.
_prompt_section() {  # _prompt_section <label> <cmd> [args...]
    local label="$1"; shift
    local out errf rc
    errf=$(mktemp) || errf=/dev/null
    out=$("$@" 2>"$errf"); rc=$?
    if [[ "$rc" -eq 0 ]]; then
        rm -f "$errf"; printf '%s' "$out"; return 0
    fi
    local first
    first=$(head -c 300 "$errf" 2>/dev/null | head -1) || first=""
    rm -f "$errf"
    printf '%s: error: wake prompt section "%s" failed: `%s` exited %s%s; the section is left out of this wakeup\n' \
        "${THINKER_NAME:-thinker}" "$label" "$*" "$rc" "${first:+ ($first)}" >&2
    if ! _prompt_section_reported "$label"; then
        jq -nc --arg label "$label" --arg cmd "$*" --argjson rc "$rc" --arg err "$first" \
            --arg source "${THINKER_NAME:-thinker}" \
            '{type:"error", content:("wake prompt section \"\($label)\" failed: `\($cmd)` exited \($rc)" + (if $err=="" then "" else ": "+$err end) + ". The section is missing from every wakeup until this is fixed."),
              source:$source, reason:"prompt-section-failed", section:$label, rc:$rc}' \
            | traj append >/dev/null 2>&1 || true
    fi
    return "$rc"
}

# Has this section's failure been recorded in the last hour?
_prompt_section_reported() {
    local label="$1" cutoff
    cutoff=$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%S 2>/dev/null) \
        || cutoff=$(date -u -v-1H +%Y-%m-%dT%H:%M:%S 2>/dev/null) || return 1
    _root_traj_raw_tail 2>/dev/null \
        | jq -R -r --arg l "$label" --arg c "$cutoff" \
            'try fromjson | select(.type=="error" and .reason=="prompt-section-failed" and .section==$l and (.ts // "") > $c) | .step_id' 2>/dev/null \
        | grep -q .
}

# Runtime line for the wake prompt: which commit the mind runs, when it was
# checked out, and when this identity's thinker copies were last synced. Gives
# a fact about the runtime a version to be keyed to — Audel spent ~half of all
# reasoning steps on 2026-09-04 re-grepping bin/shellm and md5summing its own
# thinkers every wake because nothing said whether they had changed. Prints
# nothing (rc 0) when the app root is not a git checkout.
_runtime_line() {
    local root="" sha="" subject head_t sync_t tool
    # The app root is the parent of the bin/ holding the mind's tools; try a
    # few in case one is shadowed (tests stub shellm in a scratch dir).
    for tool in shellm traj mem; do
        root=$(cd "$(dirname "$(command -v "$tool" 2>/dev/null || echo /nonexistent/x)")/.." 2>/dev/null && pwd -P) || continue
        sha=$(git -C "$root" rev-parse --short HEAD 2>/dev/null) && [[ -n "$sha" ]] && break
        sha=""
    done
    [[ -n "$sha" ]] || return 0
    subject=$(git -C "$root" log -1 --format=%s 2>/dev/null | cut -c1-60) || subject=""
    head_t=$(_mtime_utc "$root/.git/HEAD")
    sync_t=""
    if [[ -d "${IDENTITY_DIR:-}/thinkers" ]]; then
        local newest
        newest=$(find "$IDENTITY_DIR/thinkers" -type f 2>/dev/null \
            | while IFS= read -r f; do stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null; done \
            | sort -n | tail -1)
        [[ -n "$newest" ]] && sync_t=$(_epoch_utc "$newest")
    fi
    printf 'Runtime: headlong %s (%s)%s%s. A fact about your own runtime that you verified under this commit holds until this line changes.\n' \
        "$sha" "$subject" "${head_t:+, checked out $head_t}" "${sync_t:+; your thinkers synced $sync_t}"
    return 0
}

_mtime_utc() {  # _mtime_utc <file> -> "YYYY-MM-DD HH:MMZ" or ""
    local t
    t=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || { printf ''; return 0; }
    _epoch_utc "$t"
}

_epoch_utc() {  # _epoch_utc <epoch> -> "YYYY-MM-DD HH:MMZ"
    date -u -d "@$1" +'%Y-%m-%d %H:%MZ' 2>/dev/null || date -u -r "$1" +'%Y-%m-%d %H:%MZ' 2>/dev/null || printf ''
}

# Workspace section for the wake prompt: the working directory every wake
# starts in, its directories with file counts, how many loose files sit at the
# top, and the head of WORKSPACE.md if the mind keeps one. Replaces the
# pwd/ls/find opening that took 12% of Audel's reasoning steps (2026-09-04).
# Bounded: at most WORKSPACE_DIRS directories, counts capped at 5000.
# Counts in the workspace section are rounded to two significant figures
# ("about 3500") so the section, which sits in the cached prefix of every
# call, does not change on every wake that adds one file.
_coarse_count() {  # _coarse_count <n> [cap]
    local n="$1" cap="${2:-}"
    [[ -n "$cap" && "$n" -ge "$cap" ]] && { printf '%s+' "$cap"; return 0; }
    if (( n < 100 )); then printf '%s' "$n"; return 0; fi
    local digits=${#n}
    local scale=$(( 10 ** (digits - 2) ))
    printf 'about %s' "$(( (n + scale / 2) / scale * scale ))"
}

_workspace_section() {  # _workspace_section <workdir>
    local wd="$1" d n loose lines=() cap=5000
    [[ -d "$wd" ]] || return 0
    local max="${WORKSPACE_DIRS:-12}"
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        n=$(find "$d" -type f 2>/dev/null | head -n "$cap" | wc -l | tr -d ' ')
        lines+=("$(printf '%s\t%s' "$n" "${d##*/}/")")
    done < <(find "$wd" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name '__pycache__' 2>/dev/null | sort)
    loose=$(find "$wd" -mindepth 1 -maxdepth 1 -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    printf 'Workspace: %s (every wake starts here; paths below are relative to it)\n' "$wd"
    if [[ ${#lines[@]} -gt 0 ]]; then
        printf '%s\n' "${lines[@]}" | sort -t$'\t' -k1,1nr | head -n "$max" \
            | while IFS=$'\t' read -r n d; do printf -- '- %s %s files\n' "$d" "$(_coarse_count "$n" "$cap")"; done
        [[ ${#lines[@]} -gt "$max" ]] && printf -- '- and %d more directories\n' $(( ${#lines[@]} - max ))
    fi
    printf -- '- %s loose files at the top level\n' "$(_coarse_count "$loose")"
    if [[ -f "$wd/WORKSPACE.md" ]]; then
        printf 'WORKSPACE.md (yours to keep current; first lines):\n'
        head -n 8 "$wd/WORKSPACE.md" | cut -c1-160
    else
        printf 'No WORKSPACE.md yet: write one (what lives where, what is in progress) and it is shown here.\n'
    fi
    return 0
}

# Sent section for the wake prompt: what the identity said outward in the
# last OUTBOUND_SINCE (24h), newest first, each with what the bridge reported
# back. Keyed by time, not by step count, so it survives any number of idle
# wakes; the 20-step recent stream lost a send after 16 idle runs on
# 2026-09-08 and the mind re-sent it three times (design/outbound_delivery.md,
# part 5). Empty output means no section. `chat sent` failing is reported by
# _prompt_section like any other section.
_outbound_section() {
    command -v chat >/dev/null 2>&1 || return 0
    local since="${OUTBOUND_SINCE:-24h}" max="${OUTBOUND_MAX:-10}" rows
    rows=$(chat sent --since "$since" -n 200 --json) || return 1
    [[ -n "$rows" && "$rows" != "[]" ]] || return 0
    printf '%s' "$rows" | jq -r --arg since "$since" --argjson max "$max" '
        def age_text: if . < 3600 then "\(. / 60 | floor)m"
                      elif . < 86400 then "\(. / 3600 | floor)h"
                      else "\(. / 86400 | floor)d" end;
        def line: "- \((.ts // "?")[0:16] | sub("T"; " "))Z to \(.to): "
                  + (if .state == "delivered" then "delivered"
                     elif .state == "failed" then "FAILED, never arrived (\(.reason // "no reason given"))"
                     elif .state == "skipped" then "not sent (\(.reason // "skipped"))"
                     elif .state == "pending" then (if .age_s > 300 then "PENDING \(.age_s | age_text), no delivery confirmation yet (the bridge may be down)" else "pending" end)
                     else "sent (this transport does not confirm delivery)" end)
                  + " \"" + ((.filename // .content // "") | gsub("\n"; " ") | if length > 70 then .[0:70] + "…" else . end) + "\"";
        "Sent in the last \($since) (newest first; `chat sent` shows more; a FAILED line means the message never reached anyone, fix the address and send again; do not send again anything listed as delivered or pending):",
        (.[:$max][] | line),
        (if length > $max then "- and \(length - $max) more: `chat sent --since \($since)`" else empty end)'
    return 0
}

# Build the common system prompt prefix shared by all thinkers.
# Calls `identity prompt` and `skills prompt` to assemble identity context.
_build_system_prompt() {
    local identity_text skills_text
    identity_text=$(_prompt_section identity identity prompt) || identity_text=""
    skills_text=$(_prompt_section skills skills prompt) || skills_text=""

    printf 'You are an unconscious thought process of an AI person named %s.\n' "$IDENTITY_NAME"
    printf '\nAbout %s:\n%s' "$IDENTITY_NAME" "$identity_text"
    if [[ -n "$skills_text" ]]; then
        printf '\n\n%s' "$skills_text"
    fi
}

# ---------------------------------------------------------------------------
# Goals
# ---------------------------------------------------------------------------

# The active-goals section of the wake prompt. Every goal-family memory
# (goal, intention, objective, todo) is shown, newest first, with its type
# and age, capped at GOALS_MAX lines plus a count of the rest. A memory
# with `until: YYYY-MM-DD` in its frontmatter drops out after that date
# (`mem add --until`). Before 2026-09-04 only goal and intention were read,
# so 10 of Audel's 13 goal memories were invisible, three were duplicates
# of a finished objective, and two todos had expired weeks earlier.
get_goals() {
    local mem_dir="${1:-$MEM_DIR}" max="${GOALS_MAX:-8}"
    [[ -d "$mem_dir" ]] || return 0
    local today now f ftype until created body age shown=0 hidden=0 goals=""
    today=$(date -u +%Y-%m-%d); now=$(date -u +%s)
    local -a files=("$mem_dir"/*.md)
    local i
    for (( i = ${#files[@]} - 1; i >= 0; i-- )); do
        f="${files[$i]}"
        [[ -f "$f" ]] || continue
        ftype=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^type:/{sub(/^type:[[:space:]]*/, ""); print}' "$f")
        case "$ftype" in goal|intention|objective|todo) ;; *) continue ;; esac
        until=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^until:/{sub(/^until:[[:space:]]*/, ""); print}' "$f")
        [[ -n "$until" && "$until" < "$today" ]] && continue
        body=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{f=0; next} !f{print}' "$f" | sed '/./,$!d' | head -3)
        [[ -n "$body" ]] || continue
        if (( shown >= max )); then hidden=$((hidden + 1)); continue; fi
        created=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^created:/{sub(/^created:[[:space:]]*/, ""); print}' "$f")
        age=$(_mem_age "$created" "$f" "$now")
        goals="${goals}- [${ftype}${age:+, $age}${until:+, until $until}] ${body}
"
        shown=$((shown + 1))
    done
    if [[ -z "$goals" ]]; then
        printf '%s' "(no goals set)"
    else
        printf '%s' "$goals"
        (( hidden > 0 )) && printf '%s' "- and $hidden more: mem list --type goal (also intention, objective, todo)"
    fi
    return 0   # the step runs under set -e; a false arithmetic test must not be the exit status
}

# Age of a memory as "3h", "5d", or "3w": from its created field, else the
# file's mtime. Empty when neither parses.
_mem_age() {
    local created="$1" file="$2" now="$3" t="" d
    if [[ -n "$created" ]]; then
        t=$(date -u -d "$created" +%s 2>/dev/null) || t=$(date -j -u -f '%Y-%m-%d %H:%M:%S' "$created" +%s 2>/dev/null) || t=""
    fi
    [[ -n "$t" ]] || t=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || t=""
    [[ -n "$t" ]] || return 0
    d=$(( now - t )); (( d < 0 )) && d=0
    if (( d < 86400 )); then printf '%sh' $(( d / 3600 ))
    elif (( d < 14 * 86400 )); then printf '%sd' $(( d / 86400 ))
    else printf '%sw' $(( d / 604800 )); fi
}

# Related memories for the wake prompt. Scores the memory store against the
# wake's own material (routing signals plus the last few stream steps) with
# mem's keyword stage (`mem prefilter`, BM25, no model call) and prints up to
# N lines: name, type, age, first sentence. Skipped: memories written in the
# last RELATED_FRESH_S (a day; they are already in the stream) and the names
# in $2 (what the previous wake showed, so an open thread does not repeat
# the same three lines every wake). Words the prompt template itself
# contributes are stripped first, or every timer wake matches the same hub
# notes ("pick what best serves the mind right now"). Empty when nothing
# scores. Trial on Audel's last eight wakes, 2026-09-04: two of three picks
# on topic per wake, none repeated across all eight, and for a pending PR
# request the pick was the note saying the box's GitHub login is pull-only.
# See design/related_memories.md.
_RELATED_STOPWORDS='mind|pick|best|serves|right|now|special|signals|pending|request|responder|already|told|would|back|waiting|strongly|prefer|doing|work|timer|wake|inner|life|deliver|result|exactly|chat|reply|follow-up|reply-to|append|observation|field|resolves|filed|note|notes|path|workdir|research-portfolio|next|evidence|only|did|live|paper|type|content|source|monolith|final|step_id|run_id|true|false|null|https|http|com|github|slack|telegram|nick|audel'
_related_memories() {  # _related_memories <query> [prev-names, one per line] [n]
    local query="$1" prev="${2:-}" n="${3:-${MONOLITH_RELATED_MEMORIES:-3}}"
    (( n > 0 )) || return 0
    [[ -d "${MEM_DIR:-}" ]] || return 0
    command -v mem >/dev/null 2>&1 || return 0
    local cleaned now fresh f name ftype created body age shown=0
    cleaned=$(printf '%s' "$query" | tr -c 'A-Za-z0-9_#@.-' '\n' | grep -vxiE "$_RELATED_STOPWORDS" | tr '\n' ' ')
    [[ -n "${cleaned// /}" ]] || return 0
    now=$(date -u +%s); fresh="${RELATED_FRESH_S:-86400}"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f" .md)
        case "$prev" in *"$name"*) continue ;; esac
        created=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^created:/{sub(/^created:[[:space:]]*/, ""); print}' "$f")
        age=$(_mem_age "$created" "$f" "$now")
        case "$age" in *h) continue ;; esac
        if [[ "$fresh" -gt 86400 && "$age" == *d ]]; then (( ${age%d} * 86400 < fresh )) && continue; fi
        ftype=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^type:/{sub(/^type:[[:space:]]*/, ""); print}' "$f")
        body=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{f=0; next} !f{print}' "$f" | sed '/./,$!d' | head -1 | sed 's/^# *//' | cut -c1-140)
        [[ -n "$body" ]] || continue
        printf -- '- %s [%s%s]: %s\n' "$name" "${ftype:-memory}" "${age:+, $age}" "$body"
        shown=$((shown + 1))
        (( shown >= n )) && break
    done < <(MEM_DIR="$MEM_DIR" mem prefilter "$cleaned" --top $(( n * 4 )) 2>/dev/null)
    return 0
}

load_prompt() {
    local prompt_file="$1"
    local identity_name="$2"
    local goals="${3:-}"
    [[ -f "$prompt_file" ]] || return 1
    local content
    content=$(cat "$prompt_file")
    content=$(printf '%s' "$content" | sed "s/{{identity_name}}/$identity_name/g")
    local goals_file
    goals_file=$(mktemp)
    printf '%s' "$goals" > "$goals_file"
    if command -v perl >/dev/null 2>&1; then
        content=$(printf '%s' "$content" | perl -pe "
            BEGIN { open(F, '<', '$goals_file'); local \$/; \$g = <F>; close(F); chomp \$g; }
            s/\\{\\{goals\\}\\}/\$g/g;
        ")
    else
        local before after
        before="${content%%\{\{goals\}\}*}"
        after="${content#*\{\{goals\}\}}"
        if [[ "$before" != "$content" ]]; then
            content="${before}${goals}${after}"
        fi
    fi
    rm -f "$goals_file"
    printf '%s' "$content"
}

# ---------------------------------------------------------------------------
# Recent stream context
# ---------------------------------------------------------------------------

# Stream the raw tail of the root trajectory without reading the whole file.
# traj cat is O(file size) — a bash read loop over every line — and the root
# log only grows (78s context builds on a 532MB file, 2026-08-12). The tail
# window (default 5000 raw lines) always contains the few dozen matching
# steps callers keep; SHELLM_RAW_TAIL_LINES widens it if that ever changes.
# Falls back to the full traj cat scan if the path can't be resolved.
_root_traj_raw_tail() {
    local _tf
    _tf=$(traj path "${ROOT_TRAJ_ID:-$TRAJ_ID}" 2>/dev/null) || _tf=""
    if [[ -n "$_tf" && -f "$_tf" ]]; then
        tail -n "${SHELLM_RAW_TAIL_LINES:-5000}" -- "$_tf" 2>/dev/null
    else
        traj cat "${ROOT_TRAJ_ID:-$TRAJ_ID}" --raw 2>/dev/null
    fi
}

# Sentinel for "the trigger step was not in the stream", distinct from both a
# verdict and an empty answer.
_RESPONDER_TRIGGER_MISSING=$'\x01trigger-not-in-window'

# Has this inbound message already been handled? Echoes the step id that says
# so (or "handled"), empty when nothing has. Three layers keyed on the trigger
# step, plus any later message from us to the same person; see the header in
# thinkers/responder/step for why a STALE claim deliberately does not count.
#
# Lives here rather than in the step script so it can be tested: the step runs
# top to bottom and cannot be sourced.
# Reads the tail first (_root_traj_raw_tail), and only falls back to the full
# `traj cat` when the trigger step is not in that window. Every record this
# looks for can only be appended AFTER the trigger, so a window holding the
# trigger holds the whole answer; a window that misses it could report an
# already-answered message as unanswered and reply twice, which is the one case
# worth paying the full scan for. Same argument fe2acd2 used moving the
# monolith's work probe off traj cat, and the cost is the same: 7.4s over a
# 308MB trajectory against 0.08s for the tail.
_responder_already_handled() {
    local trigger="$1" them="$2" cutoff="$3" out tf
    tf=$(traj path "${ROOT_TRAJ_ID:-$TRAJ_ID}" 2>/dev/null) || tf=""
    if [[ -z "$tf" || ! -f "$tf" ]]; then
        # No bounded read available: _root_traj_raw_tail would itself degrade
        # to a full traj cat, and a trigger missing from that stream would
        # trigger a second one. One full scan, not two.
        traj cat "${ROOT_TRAJ_ID:-$TRAJ_ID}" --raw 2>/dev/null \
            | _responder_scan "$trigger" "$them" "$cutoff"
        return
    fi
    out=$(_root_traj_raw_tail | _responder_scan "$trigger" "$them" "$cutoff" --require-trigger)
    if [[ "$out" == "$_RESPONDER_TRIGGER_MISSING" ]]; then
        traj cat "${ROOT_TRAJ_ID:-$TRAJ_ID}" --raw 2>/dev/null \
            | _responder_scan "$trigger" "$them" "$cutoff"
    else
        printf '%s' "$out"
    fi
}


# The scan itself, over whatever stream it is given. With --require-trigger it
# emits the sentinel instead of a verdict when the trigger step is absent, so
# the caller can tell "nothing has handled this" from "I could not see far
# enough to know".
_responder_scan() {
    local require_trigger=0
    [[ "${4:-}" == "--require-trigger" ]] && require_trigger=1
    jq -Rrn --arg me "$IDENTITY_NAME" --arg them "$2" --arg t "$1" --arg cutoff "$3" \
           --arg missing "$_RESPONDER_TRIGGER_MISSING" --argjson require "$require_trigger" '
        [inputs | fromjson? // empty] as $steps
        | ([$steps | to_entries[] | select(.value.step_id == $t)] | last) as $in
        | if $require == 1 and $in == null then $missing else
        [$steps[] | select(.type == "message" and .from == $me
                             and (.reply_to // "") == $t)]
          + [$steps[] | select(.type == "observation"
                               and (.trigger_step // "") == $t
                               and ((.decision // "") == "replied"
                                    or (.decision // "") == "no-reply"))]
          + [$steps[] | select(.type == "reply_claim"
                               and (.trigger_step // "") == $t
                               and $cutoff != ""
                               and (.ts // "") > $cutoff)]
          + (if $in == null then []
             else [$steps[($in.key + 1):][]
                   | select(.type == "message" and .from == $me and .to == $them
                            and ((.reply_to // "") == "" or (.reply_to // "") == $t))]
             end)
        | if length == 0 then empty
          else (.[0].step_id // "handled") end
          end' 2>/dev/null \
        | head -n 1
}

# Build a compact recent-stream context for thinker prompts: meaningful step
# types only, long content truncated. Excluding bulky machinery steps (prompt,
# shell-output, shellm-run, ...) keeps thinker prompts small AND prevents
# recursive inflation: a thinker's own prompt step must never be re-embedded
# in the context of its next run.
#
# Since 2026-09-02 (design/conversation_memory.md, part 3; controlled replay
# in Experiment B passed):
#   - `reasoning` steps are OUT. They are the model's prose between bash blocks
#     inside a shellm run, about 5.6 per run, and they were half of every
#     window; the replay showed the mind copied them back as ritual and never
#     used them as information. `final` (one per run, what the run concluded)
#     stays.
#   - runs of consecutive `idle` steps collapse into one synthetic line
#     ("idle x22 over 2h10m", with `collapsed: 22`), so a quiet night still
#     reads as elapsed time without eating the whole window.
#   - `error` steps (a run that died with no durable step) are IN, collapsed
#     the same way, so the mind can see its own failed runs.
# The window is the last N kept steps BEFORE collapsing, so N still bounds the
# raw steps considered; the output is at most N lines and usually fewer.
_RECENT_STREAM_COLLAPSE_JQ='
  def secs: ((. // "")[0:19] + "Z") | try fromdateiso8601 catch null;
  def dur($a; $b):
    (($b | secs) as $e | ($a | secs) as $s
     | if $e == null or $s == null then "" else ($e - $s) end) as $d
    | if $d == "" then ""
      elif $d < 60 then "\($d)s"
      elif $d < 3600 then "\(($d / 60) | floor)m"
      elif $d < 86400 then "\(($d / 3600) | floor)h\((($d % 3600) / 60) | floor)m"
      else "\(($d / 86400) | floor)d\((($d % 86400) / 3600) | floor)h" end;
  def collapsible: .type == "idle" or .type == "error";
  reduce .[] as $s ([];
    if ($s | collapsible) and length > 0 and .[-1].type == $s.type
    then .[:-1] + [ .[-1] | .n += 1 | .last_ts = ($s.ts // .last_ts)
                    | .step_id = ($s.step_id // .step_id) | .rc = ($s.rc // .rc) ]
    else . + [ $s + {n: 1, first_ts: ($s.ts // ""), last_ts: ($s.ts // "")} ] end)
  | map(if (. | collapsible) and .n > 1
        then (dur(.first_ts; .last_ts)) as $d
             | .content = (if .type == "idle" then "idle" else "run failed" end)
                          + " x\(.n)" + (if $d == "" then "" else " over \($d)" end)
                          + (if .type == "error" and .rc != null then " (rc=\(.rc))" else "" end)
             | .collapsed = .n
        else . end
        | del(.n, .first_ts, .last_ts))
  | .[]'

# An idle run writes an idle step and then a final that says the same thing
# ("Idle — nothing to do"); the final is dropped so a string of idle wakes
# collapses to one "idle xN" line instead of two steps per wake. Sixteen idle
# runs on 2026-09-08 took 48 of the window's 20 slots in 35 minutes and the
# mind lost sight of a send it had just made (design/outbound_delivery.md).
# An observation followed by its run's final is the same report written
# twice: the prompt asks for both, and the model writes the handoff into each
# (7 of 20 stream slots on Audel, 2026-09-04). When a final arrives, the
# nearest earlier observation with the same run id is dropped; earlier
# observations in a long run stay as milestones, and an observation whose run
# never reached a final (killed, errored) stays as its only record. Runs
# before the tail cut so N still means N distinct events.
_RECENT_STREAM_PAIR_JQ='
  reduce .[] as $s ([];
    if $s.type == "final" and (($s.run_id // "") | tostring) != ""
    then ($s.run_id | tostring) as $r
         | (to_entries
            | map(select(.value.type == "observation" and ((.value.run_id // "") | tostring) == $r))
            | last | .key) as $j
         | if $j != null then del(.[$j]) + [$s]
           elif (map(select(.type == "idle" and ((.run_id // "") | tostring) == $r)) | length) > 0 then .
           else . + [$s] end
    else . + [$s] end)
  | .[]'

# A run's final is all the next wake sees of that run (the mind's render is
# run scoped, so earlier runs' commands and outputs are not in its context),
# so each final carries a `details` command that prints the run's raw steps.
# Only the fields the mind can use are kept: the responder stamps metrics on
# its observations (context_steps, a list of 27 UUIDs, compose_ms, model,
# ...) for audel-metrics, and those were 10K of a 17K stream on Audel,
# 2026-09-03. Ids are cut to 8 characters (traj accepts a prefix), except
# trigger_step and resolves, which the mind copies verbatim; the details
# command keeps the full run id because the traj filter matches exactly.
# Failed `delivery` steps (a bridge could not post an outbound message) are
# admitted so the mind learns at its next wake that it did not actually speak;
# delivered ones are not, they would double every send inside the window and
# belong to the sent ledger (design/outbound_delivery.md, part 4).
_recent_stream() {
    local n="${1:-${THINK_CONTEXT_TAIL:-20}}"
    # Tolerant parse (fromjson?): skip corrupt lines rather than dying —
    # concurrent appends have historically produced occasional bad lines.
    _root_traj_raw_tail \
        | jq -cR 'fromjson? // empty
            | select(.type == "thought" or .type == "action" or .type == "observation"
                     or .type == "message" or .type == "idle" or .type == "merge"
                     or .type == "final" or .type == "error"
                     or (.type == "delivery" and .status == "failed"))
            | del(.content_b64)
            | .content = (
                (if ((.content // "") == "") and ((.filename // "") != "")
                 then "[file: \(.filename)]"
                 else (.content // "") end)
                | tostring
                | if length > 1500 then .[0:1500] + "…[truncated]" else . end)
            | if .type == "final" and ((.run_id // "") | tostring) != ""
              then .details = "traj tail -n 400 --filter run_id=" + (.run_id | tostring) else . end
            | with_entries(select(.key | IN("type", "content", "source", "ts", "from", "to", "run_id", "step_id", "request", "person", "resolves", "trigger_step", "reply_to", "follow_up", "decision", "deferred", "rc", "details", "status", "reason")))' \
        2>/dev/null \
        | jq -cs "$_RECENT_STREAM_PAIR_JQ" 2>/dev/null \
        | tail -n "$n" \
        | jq -cs "$_RECENT_STREAM_COLLAPSE_JQ" 2>/dev/null \
        | jq -c '.ts |= (tostring | .[0:16])
            | .step_id |= (tostring | .[0:8])
            | if .run_id then .run_id |= (tostring | .[0:8]) else . end' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Tiered "life so far" context
# ---------------------------------------------------------------------------

# Assemble a budget-bounded staircase of tiered rollups (coarse→fine) spanning
# the whole root trajectory, via `recap --context`. Gives the mind its entire
# life at level-of-detail instead of just the last N steps. Falls back to empty
# (caller keeps _recent_stream) on any error, so the loop never breaks.
# See design/tiered_memory.md.
# Rollup model: the explicit knobs win over the generic cheap class.
# ROLLUP_MODEL, then recap's own RECAP_MAP_MODEL, then SHELLM_FAST_MODEL.
# Passing the fast class as --map-model would override a RECAP_MAP_MODEL the
# operator pinned (Audel's rollups are on sonnet while its fast class is a
# flash model), and the life summary is the mind's long-term memory.
_life_context() {
    command -v recap >/dev/null 2>&1 || return 0
    local mm=() m="${ROLLUP_MODEL:-${RECAP_MAP_MODEL:-${SHELLM_FAST_MODEL:-}}}"
    [[ -n "$m" ]] && mm=(--map-model "$m")
    # No verbatim raw tail by default: the monolith renders its own recent
    # stream (the last durable steps, with a traj tail pointer), so recap's
    # raw tail only repeated it (127 lines of wake and final rows on Audel,
    # 2026-09-03). ROLLUP_RAW_TAIL still overrides.
    recap "${ROOT_TRAJ_ID:-$TRAJ_ID}" --context \
        --budget "${MONOLITH_CONTEXT_BUDGET:-auto}" \
        --raw-tail "${ROLLUP_RAW_TAIL:-0}" \
        ${mm[@]+"${mm[@]}"} -q 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Skill variable collection
# ---------------------------------------------------------------------------

# Collect env vars declared by skills via SKILL.md frontmatter metadata
collect_skill_vars() {
    local identity_dir="$1"
    local -a var_names=()
    local -a dirs=("${SKILLS_KERNEL_DIR:-$identity_dir/kernel}" "$identity_dir/skills")
    local base skill_dir
    for base in "${dirs[@]}"; do
        [[ -d "$base" ]] || continue
        for skill_dir in "$base"/*/; do
            [[ -f "${skill_dir}SKILL.md" ]] || continue
            local frontmatter
            frontmatter=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f{print}' "${skill_dir}SKILL.md")
            [[ -z "$frontmatter" ]] && continue
            local env_val
            env_val=$(printf '%s\n' "$frontmatter" | awk '/^[[:space:]]+env:/{sub(/.*env:[[:space:]]*/, ""); print; exit}')
            [[ -z "$env_val" ]] && continue
            local v
            while IFS= read -r v; do
                [[ -n "$v" ]] && var_names+=("$v")
            done < <(printf '%s' "$env_val" | jq -r '.[]' 2>/dev/null)
        done
    done
    if [[ ${#var_names[@]} -gt 0 ]]; then
        printf '%s\n' "${var_names[@]}" | sort -u
    fi
}

# Bare `--var NAME` is resolved from shellm's inherited environment. Export
# skill values in the caller before flag assembly runs in process substitution,
# whose subshell cannot export anything back to its parent.
_export_skill_vars() {
    local identity_dir="$1" vname
    while IFS= read -r vname; do
        [[ -n "$vname" && -n "${!vname:-}" ]] && export "${vname?}"
    done < <(collect_skill_vars "$identity_dir")
    # Callers run under set -e: a declared-but-unset last var must not end the
    # function on a false test (it killed every Audel wake on 2026-09-05).
    return 0
}

_export_provider_keys() {
    local vname
    for vname in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
                 OPENCODE_API_KEY LLM_API_KEY; do
        [[ -n "${!vname:-}" ]] && export "${vname?}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

# Resolve a directory to an absolute path
_abs_path() {
    local dir="$1"
    (cd "$dir" 2>/dev/null && pwd) || printf '%s' "$dir"
}

# Build common shellm flags: --env, --workdir, --var, --bin.
# Honors SHELLM_THINKER_ENV to override the env (e.g. =local to skip Docker).
_build_shellm_flags() {
    local identity_dir="$1"
    local run_dir="${2:-$identity_dir/workdir}"
    local abs_mem_dir abs_skills_dir abs_kernel_dir abs_traj_dir

    abs_mem_dir=$(_abs_path "$MEM_DIR")
    abs_skills_dir=$(_abs_path "$SKILLS_DIR")
    abs_kernel_dir=$(_abs_path "$SKILLS_KERNEL_DIR")
    abs_traj_dir=$(_abs_path "$TRAJ_DIR")

    printf '%s\n' "--env" "${SHELLM_THINKER_ENV:-$IDENTITY_NAME}"
    printf '%s\n' "--workdir" "$run_dir"
    # IDENTITY_NAME must reach the generated code's env: `chat reply` dies
    # without it (observed: actor unable to reply, model flailing into
    # `chat send` variants). Non-directory --var values are plain env vars.
    printf '%s\n' "--var" "IDENTITY_NAME=$IDENTITY_NAME"
    printf '%s\n' "--var" "MEM_DIR=$abs_mem_dir"
    printf '%s\n' "--var" "SKILLS_DIR=$abs_skills_dir"
    printf '%s\n' "--var" "SKILLS_KERNEL_DIR=$abs_kernel_dir"
    printf '%s\n' "--var" "TRAJ_DIR=$abs_traj_dir"
    printf '%s\n' "--var" "TRAJ_ID=$TRAJ_ID"
    # chat reads the identity-specific sender config through CHATRC. The
    # identity directory is already mounted into Docker; only the path was
    # missing from generated-code runs.
    printf '%s\n' "--var" "CHATRC=${CHATRC:-$identity_dir/chat/.chatrc}"

    # Propagate model + API keys to nested shellm calls. Inside Docker, .env
    # isn't mounted, so without these the nested call hits the final else in
    # bin/shellm's model fallback and fails with "ANTHROPIC_API_KEY is not set".
    # Keys go by NAME (bare `--var NAME`): shellm reads the value from its
    # environment, so it never shows up in `ps` or the recorded command line.
    [[ -n "${SHELLM_MODEL:-}" ]] && printf '%s\n' "--var" "SHELLM_MODEL=$SHELLM_MODEL"
    # The generic openai-compatible provider is env-configured and never
    # auto-detected, so nested calls need the provider name (routing, not a
    # secret) and key. Endpoint variables are inherited rather than repeated
    # as --var: shellm rewrites their values for Docker, and a duplicate extra
    # var would overwrite that rewritten value in generated code.
    [[ -n "${LLM_PROVIDER:-}" ]] && printf '%s\n' "--var" "LLM_PROVIDER=$LLM_PROVIDER"
    for _ak in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
               OPENCODE_API_KEY LLM_API_KEY; do
        if [[ -n "${!_ak:-}" ]]; then
            printf '%s\n' "--var" "$_ak"
        fi
    done

    # Skill-declared vars
    while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        # shellm owns endpoint alias resolution and Docker rewriting. Emitting
        # either alias again as an extra var would overwrite its canonical URL.
        case "$vname" in LLM_API_URL|SHELLM_API_URL) continue ;; esac
        local vval="${!vname:-}"
        if [[ -n "$vval" ]]; then
            # Skills commonly declare credentials and service endpoints. Keep
            # every declared value off argv rather than trying to infer which
            # names are sensitive.
            printf '%s\n' "--var" "$vname"
        fi
    done < <(collect_skill_vars "$identity_dir")

    # Standard binaries. Keep this in sync with the tools promised to the
    # running mind in README.md and the stock identity prompt: a host-only tool
    # silently disappears when shellm switches to Docker.
    local cmd
    for cmd in mem traj skills context llm shellm chat recap; do
        local path
        path=$(command -v "$cmd" 2>/dev/null) || continue
        printf '%s\n' "--bin" "$path"
    done
}
