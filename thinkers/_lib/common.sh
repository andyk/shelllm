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

# Build the common system prompt prefix shared by all thinkers.
# Calls `identity prompt` and `skills prompt` to assemble identity context.
_build_system_prompt() {
    local identity_text skills_text
    identity_text=$(identity prompt 2>/dev/null) || identity_text=""
    skills_text=$(skills prompt 2>/dev/null) || skills_text=""

    printf 'You are an unconscious thought process of an AI person named %s.\n' "$IDENTITY_NAME"
    printf '\nAbout %s:\n%s' "$IDENTITY_NAME" "$identity_text"
    if [[ -n "$skills_text" ]]; then
        printf '\n\n%s' "$skills_text"
    fi
}

# ---------------------------------------------------------------------------
# Goals
# ---------------------------------------------------------------------------

# Extract goals from identity's memories (type: goal/intention)
get_goals() {
    local mem_dir="${1:-$MEM_DIR}"
    [[ -d "$mem_dir" ]] || return 0
    local goals=""
    local f
    for f in "$mem_dir"/*.md; do
        [[ -f "$f" ]] || continue
        local ftype
        ftype=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{exit} f && /^type:/{sub(/^type:[[:space:]]*/, ""); print}' "$f")
        case "$ftype" in
            goal|intention)
                local body
                body=$(awk 'NR==1 && /^---$/{f=1; next} f && /^---$/{f=0; next} !f{print}' "$f" | sed '/./,$!d' | head -3)
                [[ -n "$body" ]] && goals="${goals}- ${body}
"
                ;;
        esac
    done
    if [[ -z "$goals" ]]; then
        printf '%s' "(no goals set)"
    else
        printf '%s' "$goals"
    fi
}

# ---------------------------------------------------------------------------
# Prompt loading
# ---------------------------------------------------------------------------

# Load a prompt template, replacing {{goals}} and {{identity_name}}
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
_recent_stream() {
    local n="${1:-${THINK_CONTEXT_TAIL:-20}}"
    # Tolerant parse (fromjson?): skip corrupt lines rather than dying —
    # concurrent appends have historically produced occasional bad lines.
    _root_traj_raw_tail \
        | jq -cR 'fromjson? // empty
            | select(.type == "thought" or .type == "action" or .type == "observation"
                     or .type == "message" or .type == "idle" or .type == "merge"
                     or .type == "final" or .type == "reasoning")
            | .content = ((.content // "") | tostring
                | if length > 1500 then .[0:1500] + "…[truncated]" else . end)' \
        2>/dev/null \
        | tail -n "$n"
}

# ---------------------------------------------------------------------------
# Tiered "life so far" context
# ---------------------------------------------------------------------------

# Assemble a budget-bounded staircase of tiered rollups (coarse→fine) spanning
# the whole root trajectory, via `recap --context`. Gives the mind its entire
# life at level-of-detail instead of just the last N steps. Falls back to empty
# (caller keeps _recent_stream) on any error, so the loop never breaks.
# See design/tiered_memory.md.
_life_context() {
    command -v recap >/dev/null 2>&1 || return 0
    local mm=() m="${ROLLUP_MODEL:-${SHELLM_FAST_MODEL:-}}"
    [[ -n "$m" ]] && mm=(--map-model "$m")
    recap "${ROOT_TRAJ_ID:-$TRAJ_ID}" --context \
        --budget "${MONOLITH_CONTEXT_BUDGET:-auto}" \
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

    # Propagate model + provider credentials to nested shellm calls. Inside
    # Docker, .env
    # isn't mounted, so without these the nested call hits the final else in
    # bin/shellm's model fallback and fails with "ANTHROPIC_API_KEY is not set".
    # Credentials and region go by NAME (bare `--var NAME`): shellm reads the
    # value from its environment, so it never shows up in `ps` or the recorded
    # command line.
    [[ -n "${SHELLM_MODEL:-}" ]] && printf '%s\n' "--var" "SHELLM_MODEL=$SHELLM_MODEL"
    for _ak in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
               AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
               AWS_SESSION_TOKEN AWS_PROFILE AWS_CONFIG_FILE \
               AWS_SHARED_CREDENTIALS_FILE AWS_REGION AWS_DEFAULT_REGION; do
        if [[ -n "${!_ak:-}" ]]; then
            export "${_ak?}"
            printf '%s\n' "--var" "$_ak"
        fi
    done

    # Skill-declared vars
    while IFS= read -r vname; do
        [[ -z "$vname" ]] && continue
        local vval="${!vname:-}"
        [[ -n "$vval" ]] && printf '%s\n' "--var" "$vname=$vval"
    done < <(collect_skill_vars "$identity_dir")

    # Standard binaries
    local cmd
    for cmd in mem traj skills context llm shellm chat glob view put sub; do
        local path
        path=$(command -v "$cmd" 2>/dev/null) || continue
        printf '%s\n' "--bin" "$path"
    done
}
