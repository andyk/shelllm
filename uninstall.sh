#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh — remove Headlong from this machine, the reverse of install.sh.
#
#   curl -fsSL https://headlong.ai/uninstall.sh | bash
#   ./uninstall.sh [options]            (from a checkout)
#   ./install.sh --uninstall            (same thing)
#
# What it does, in order, with a confirmation before anything destructive:
#   1. Stops every running Headlong process (dispatchers, thinker steps,
#      shellm runs, the dash) — shown first, then confirmed.
#   2. Moves your agent's identities (memories, trajectory) to a backup
#      folder in your home directory, unless you say to delete them.
#   3. Removes: the state home (~/.headlong: .env, logs, the checkout),
#      the tool links/copies in ~/.local/bin, ~/.skills/core-skills,
#      ~/.headlong-thinkers, and the PATH line install.sh added to your rc.
#
# Everything side-effectful happens inside main(), invoked on the LAST line
# of this file, so a partially downloaded script executes nothing.

HEADLONG_HOME="${HEADLONG_HOME:-$HOME/.headlong}"
PREFIX="${PREFIX:-$HOME/.local/bin}"
YES=0
DRY_RUN=0
STOP=1                # --no-stop: leave running processes alone
IDENTITIES="ask"      # ask | keep | delete
# Same list as install.sh (BIN_TOOLS + AUX_TOOLS + the TUI binary). Kept
# here too so this script works standalone, after the checkout is gone;
# tests/test_uninstall.sh checks the two lists agree.
TOOLS=(shellm shellm-docker skills mem llm responses context traj thinkers chat recap
       shellm-docker-broker identity shellm-explore headlong-skills headlong-init headlong-killall persona headlong-web
       headlong-slack-bridge headlong-telegram-bridge responses-ws headlong-tui)

_usage() {
    cat <<'EOF'
Usage: uninstall.sh [options]

Stops every running Headlong process and removes what install.sh put on this
machine. Your agent's identities (memories, trajectory) are moved to a backup
folder in your home directory unless you choose to delete them.

Options:
  --yes               Don't ask; stop processes and remove everything
                      (identities are still backed up unless --delete-identities)
  --keep-identities   Back up identities without asking (default when --yes)
  --delete-identities Delete identities too, no backup
  --dry-run           Show what would happen, change nothing
  --no-stop           Don't stop running processes, only remove files
  --prefix DIR        Where the tools were installed (default: ~/.local/bin)
  -h, --help          Show this help

Environment:
  HEADLONG_HOME       State directory (default: ~/.headlong)
  PREFIX              Same as --prefix
EOF
}

say()   { printf '%s\n' "$*"; }
head_() { printf '\n==> %s\n' "$*"; }
die()   { printf 'uninstall.sh: error: %s\n' "$*" >&2; exit 1; }

HAS_TTY=0
if (: </dev/tty) 2>/dev/null; then HAS_TTY=1; fi

# ask_yn <prompt> <default y|n> — reads /dev/tty (stdin may be the curl pipe).
# --yes answers yes to everything; with no tty the default answers.
ask_yn() {
    local prompt="$1" def="$2" reply=""
    [[ "$YES" -eq 1 ]] && return 0
    if [[ "$HAS_TTY" -eq 0 ]]; then
        [[ "$def" == y ]]; return
    fi
    if [[ "$def" == y ]]; then printf '%s [Y/n] ' "$prompt" >/dev/tty; else printf '%s [y/N] ' "$prompt" >/dev/tty; fi
    IFS= read -r reply </dev/tty || true
    reply="${reply:-$def}"
    [[ "$reply" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

APP_DIR=""
_find_app_dir() {
    local recorded
    recorded=$(cat "$HEADLONG_HOME/app_dir" 2>/dev/null || true)
    if [[ -n "$recorded" && -f "$recorded/bin/shellm" ]]; then APP_DIR="$recorded"; return 0; fi
    if [[ -f "$HEADLONG_HOME/app/bin/shellm" ]]; then APP_DIR="$HEADLONG_HOME/app"; return 0; fi
    # From a checkout: this script sits next to install.sh
    local here; here="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"
    if [[ -f "$here/bin/shellm" ]]; then APP_DIR="$here"; return 0; fi
    return 1
}

# The checkout is ours to delete only when install.sh cloned it into the
# state home (the one-liner). A clone the user made themselves, and the
# .identities inside it, stay put — it's their working copy.
_app_is_ours() {
    [[ -n "$APP_DIR" && "$APP_DIR" == "$HEADLONG_HOME"/* ]]
}
_identity_root() {
    _app_is_ours && [[ -d "$APP_DIR/.identities" ]] && printf '%s' "$APP_DIR/.identities"
    return 0
}

# Tool entries in PREFIX that are ours: names from the list, plus any symlink
# that points at a persona/headlong tool (the `ada` -> persona links, and
# symlink-mode installs pointing into the checkout).
_our_prefix_entries() {
    local f name target t
    [[ -d "$PREFIX" ]] || return 0
    for f in "$PREFIX"/*; do
        [[ -e "$f" || -L "$f" ]] || continue
        name=$(basename "$f")
        for t in "${TOOLS[@]}"; do [[ "$name" == "$t" ]] && { printf '%s\n' "$f"; continue 2; }; done
        if [[ -L "$f" ]]; then
            target=$(readlink "$f")
            case "$target" in
                */persona) printf '%s\n' "$f" ;;
                "$APP_DIR"/bin/*|"$APP_DIR"/tools/*) [[ -n "$APP_DIR" ]] && printf '%s\n' "$f" ;;
            esac
        fi
    done
    return 0
}

# rc files that carry the exact PATH line install.sh writes
_rc_files_with_path_line() {
    local line="export PATH=\"$PREFIX:\$PATH\"" rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
        [[ -f "$rc" ]] && grep -qxF "$line" "$rc" && printf '%s\n' "$rc"
    done
    return 0
}

# Running processes. Prefer the checkout's own headlong-killall (exact argv
# patterns); fall back to a conservative pgrep over the same shapes so the
# uninstaller still works when the checkout is already gone.
_killall_bin() {
    if [[ -n "$APP_DIR" && -x "$APP_DIR/tools/headlong-killall" ]]; then printf '%s' "$APP_DIR/tools/headlong-killall"; return 0; fi
    command -v headlong-killall 2>/dev/null && return 0
    return 1
}
# Process shapes, copied from headlong-killall (the source of truth) for the
# case where the checkout is already gone; tests/test_status.sh checks parity.
PATTERNS=(
    'bash [^ ]*/(bin|tools)/(shellm|shellm-explore|llm|chat)( |$)'
    'bash [^ ]*/bin/thinkers( |$)'
    'bash [^ ]*/thinkers/[^ /]+/step( |$)'
    'bash [^ ]*/bin/traj tail'
    'tail -n 0 -F [^ ]*trajectory\.jsonl'
)
DASH_PAT='(uv run --project [^ ]+ |/\.venv/bin/)(headlong|shellm|shelly)-web( |$)'
_list_processes() {
    local k
    {
        if k=$(_killall_bin); then
            "$k" --dry-run --web 2>/dev/null | sed -n 's/^  //p'
        else
            local pat
            for pat in "${PATTERNS[@]}"; do pgrep -fl "$pat" 2>/dev/null || true; done
        fi
        # The dash, by our own pattern too: an older checkout's killall
        # predates the headlong-web name and would miss it.
        pgrep -fl "$DASH_PAT" 2>/dev/null || true
    } | grep -E '^[0-9]+ ' | grep -v " $$ " | sort -un -k1,1
}
_kill_processes() {
    local k pids
    pids=$(_list_processes | awk '{print $1}' || true)
    if k=$(_killall_bin); then "$k" --web >/dev/null 2>&1 || true; fi
    # Whatever killall did not know about (the dash on old checkouts), plus
    # stragglers: TERM, a moment, KILL.
    local alive=""
    local p; for p in $pids; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
    [[ -n "$alive" ]] || return 0
    # shellcheck disable=SC2086
    kill -TERM $alive 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    kill -KILL $alive 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y)            YES=1; shift ;;
            --keep-identities)   IDENTITIES=keep; shift ;;
            --delete-identities) IDENTITIES=delete; shift ;;
            --dry-run|-n)        DRY_RUN=1; shift ;;
            --no-stop)           STOP=0; shift ;;
            --prefix)            PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
            -h|--help)           _usage; exit 0 ;;
            *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
        esac
    done
    [[ "$YES" -eq 1 && "$IDENTITIES" == ask ]] && IDENTITIES=keep

    _find_app_dir || true
    local idroot; idroot=$(_identity_root || true)
    local -a entries=() rcs=()
    local l
    while IFS= read -r l; do [[ -n "$l" ]] && entries+=("$l"); done < <(_our_prefix_entries)
    while IFS= read -r l; do [[ -n "$l" ]] && rcs+=("$l"); done < <(_rc_files_with_path_line)
    local procs=""
    [[ "$STOP" -eq 1 ]] && procs=$(_list_processes || true)
    local nprocs=0; [[ -n "$procs" ]] && nprocs=$(printf '%s\n' "$procs" | grep -c '' || true)

    local found=0
    [[ -d "$HEADLONG_HOME" || "${#entries[@]}" -gt 0 || -d "$HOME/.skills/core-skills" || -d "$HOME/.headlong-thinkers" || "${#rcs[@]}" -gt 0 || "$nprocs" -gt 0 ]] && found=1
    if [[ "$found" -eq 0 ]]; then
        say "Nothing to do: no Headlong install found (looked in $HEADLONG_HOME, $PREFIX, ~/.skills/core-skills, ~/.headlong-thinkers)."
        exit 0
    fi

    # --- 1. processes: show, ask, stop --------------------------------------
    say
    if [[ "$DRY_RUN" -eq 1 ]]; then say "Headlong uninstall (dry run)"; else say "Headlong uninstall"; fi
    head_ "Running Headlong processes"
    local killall_hint="headlong-killall --dry-run --web"
    local k; if k=$(_killall_bin); then killall_hint="$k --dry-run --web"; fi
    if [[ "$STOP" -eq 0 ]]; then
        say "  (not checked: --no-stop)"
    elif [[ "$nprocs" -gt 0 ]]; then
        # A glance, not a dump: the first few, each cut to one line. Feed
        # head from a here-string, not a printf pipe: head closing early
        # would EPIPE the printf builtin and, under pipefail + set -e, kill
        # the script right here (seen with >6 processes).
        head -6 <<<"$procs" | cut -c1-"${COLUMNS:-100}" | sed 's/^/  /'
        [[ "$nprocs" -gt 6 ]] && say "  ... and $((nprocs - 6)) more"
        say
        say "  Full list:  $killall_hint"
    else
        say "  none"
    fi
    if [[ "$nprocs" -gt 0 && "$DRY_RUN" -eq 0 ]]; then
        if [[ "$YES" -eq 0 && "$HAS_TTY" -eq 0 ]]; then
            die "no terminal to confirm on. Re-run with --yes to proceed without prompts (see --help)."
        fi
        say
        if ask_yn "Stop these $nprocs process(es)?" n; then
            head_ "Stopping processes"
            _kill_processes
            say "  done"
        else
            say
            say "Leaving them running; nothing changed. Stop them yourself (ada stop, or"
            say "$killall_hint without --dry-run) and re-run, or pass --no-stop to remove"
            say "the files anyway."
            exit 1
        fi
    fi

    # --- 2. files: show, ask, remove ---------------------------------------
    head_ "Will remove"
    if _app_is_ours; then
        say "  $APP_DIR   (the checkout)"
    elif [[ -n "$APP_DIR" ]]; then
        say "  (your own checkout at $APP_DIR, and the .identities inside it, stay in place)"
    fi
    [[ -d "$HEADLONG_HOME" ]]      && say "  $HEADLONG_HOME   (.env with your API key, logs, status)"
    if [[ "${#entries[@]}" -gt 0 ]]; then
        local names; names=$(printf '%s ' "${entries[@]##*/}")
        say "  ${#entries[@]} tool link(s)/copies in $PREFIX"
        say "    ${names% }" | fold -s -w 76 | sed '2,$s/^/    /'
    fi
    [[ -d "$HOME/.skills/core-skills" ]] && say "  $HOME/.skills/core-skills"
    [[ -d "$HOME/.headlong-thinkers" ]]  && say "  $HOME/.headlong-thinkers"
    [[ "${#rcs[@]}" -gt 0 ]]       && say "  the PATH line for $PREFIX in: ${rcs[*]}"
    local backup=""
    if [[ -n "$idroot" ]]; then
        head_ "Your agent's identities (memories, trajectories)"
        say "  $idroot"
        local d
        for d in "$idroot"/*/; do
            [[ -d "$d" && "$(basename "$d")" != default ]] && say "    $(basename "$d")"
        done
        case "$IDENTITIES" in
            delete) say "  -> will be DELETED (--delete-identities)" ;;
            keep)   backup="$HOME/headlong-identities-backup-$(date +%Y%m%d-%H%M%S)"; say "  -> will be moved to $backup" ;;
            ask)
                say
                if ask_yn "  Keep a backup of them in your home directory?" y; then
                    backup="$HOME/headlong-identities-backup-$(date +%Y%m%d-%H%M%S)"
                    say "  -> will be moved to $backup"
                else
                    say "  -> will be DELETED"
                fi ;;
        esac
    fi
    say

    if [[ "$DRY_RUN" -eq 1 ]]; then say "Dry run: nothing changed."; exit 0; fi
    if [[ "$YES" -eq 0 && "$HAS_TTY" -eq 0 ]]; then
        die "no terminal to confirm on. Re-run with --yes to proceed without prompts (see --help)."
    fi
    ask_yn "Remove everything listed?" n || { say "Aborted; files left in place."; exit 1; }

    # --- do it --------------------------------------------------------------
    if [[ -n "$idroot" && -n "$backup" ]]; then
        head_ "Backing up identities"
        mv "$idroot" "$backup"
        say "  $backup"
    fi
    head_ "Removing files"
    local e
    for e in "${entries[@]+"${entries[@]}"}"; do rm -f "$e"; done
    [[ "${#entries[@]}" -gt 0 ]] && say "  $PREFIX: ${#entries[@]} entries"
    if [[ -d "$HEADLONG_HOME" ]]; then rm -rf "${HEADLONG_HOME:?}"; say "  $HEADLONG_HOME"; fi
    if [[ -d "$HOME/.skills/core-skills" ]]; then rm -rf "${HOME:?}/.skills/core-skills"; rmdir "$HOME/.skills" 2>/dev/null || true; say "  $HOME/.skills/core-skills"; fi
    if [[ -d "$HOME/.headlong-thinkers" ]]; then rm -rf "${HOME:?}/.headlong-thinkers"; say "  $HOME/.headlong-thinkers"; fi
    local rc line="export PATH=\"$PREFIX:\$PATH\"" tmp
    for rc in "${rcs[@]+"${rcs[@]}"}"; do
        tmp=$(mktemp)
        grep -vxF "$line" "$rc" > "$tmp" || true
        cat "$tmp" > "$rc"; rm -f "$tmp"
        say "  PATH line removed from $rc"
    done
    rmdir "$PREFIX" 2>/dev/null || true

    say
    say "Headlong is uninstalled."
    say
    if [[ -n "$backup" ]]; then
        say "  Identities backed up to:  $backup"
        say "  Delete the backup later:  rm -rf '$backup'"
        say
    fi
    [[ "${#rcs[@]}" -gt 0 ]] && say "  PATH changed: open a new terminal."
    say "  Reinstall any time:  curl -fsSL https://headlong.ai/install.sh | bash"
    say
}

main "$@"
