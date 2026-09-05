#!/usr/bin/env bash
set -euo pipefail

# install.sh — install Headlong's tools onto PATH.
#
# Two ways in:
#
#   From a checkout:
#     ./install.sh [options]
#
#   One-liner (no checkout needed):
#     curl -fsSL https://headlong.ai/install.sh | bash
#
# The one-liner clones the repo to ~/.headlong/app, symlink-installs the
# tools, then hands off to `headlong-init` to bootstrap a first identity and
# start the local dash. Pass args through the pipe with `| bash -s -- <args>`.
#
# Prefer to read before you run? Same thing, two steps:
#     curl -fsSLO https://headlong.ai/install.sh
#     less install.sh && bash install.sh --init
#
# Everything side-effectful happens inside main(), invoked on the LAST line of
# this file — so a partially downloaded script (a dropped connection mid
# `curl | bash`) parses but executes nothing. Keep it that way: top level is
# only defaults, function definitions, and that final call.

# State home: HEADLONG_HOME if set; else ~/.headlong. (An install from a
# pre-headlong era lives in ~/.shelly or ~/.shellm — move it:
# mv ~/.shelly ~/.headlong)
# Whether the OPERATOR exported HEADLONG_REPO (before the default below
# replaces "unset" with the public URL): decides if the container path may
# retarget to this checkout's own origin/branch.
HEADLONG_REPO_OPERATOR_SET="${HEADLONG_REPO+set}"
HEADLONG_REPO="${HEADLONG_REPO:-https://github.com/laude-institute/headlong.git}"
HEADLONG_BRANCH="${HEADLONG_BRANCH:-main}"
HEADLONG_HOME="${HEADLONG_HOME:-$HOME/.headlong}"

PREFIX="${PREFIX:-$HOME/.local/bin}"
SYMLINKS="${SYMLINKS:-0}"
RUN_INIT=0
# Core agent tools (bin/) and the management/aux CLIs around them (tools/).
BIN_TOOLS=(shellm shellm-docker skills mem llm responses context traj thinkers chat recap)
AUX_TOOLS=(shellm-docker-broker identity shellm-explore headlong-skills headlong-init headlong-killall persona headlong-web headlong-slack-bridge headlong-telegram-bridge)
TOOLS=("${BIN_TOOLS[@]}" "${AUX_TOOLS[@]}")

# ---------------------------------------------------------------------------
# Dependency checks (shared by both modes)
# ---------------------------------------------------------------------------

_pkg_hint() {
    local pkg="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        printf 'brew install %s' "$pkg"
    elif command -v apt-get >/dev/null 2>&1; then
        printf 'sudo apt-get install -y %s' "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        printf 'sudo dnf install -y %s' "$pkg"
    else
        printf 'install %s with your package manager' "$pkg"
    fi
}

_require_deps() {
    local missing=() failed=0 dep
    for dep in "$@"; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    [[ "${#missing[@]}" -eq 0 ]] && return 0

    # Already root with apt available — a fresh container, typically — so
    # just install them. Still no sudo anywhere: as a normal user we only
    # print the hints below.
    if [[ "$(id -u)" -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
        echo "==> Installing missing dependencies: ${missing[*]}"
        apt-get update -qq >/dev/null && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates "${missing[@]}" >/dev/null || true
    fi

    for dep in "${missing[@]}"; do
        command -v "$dep" >/dev/null 2>&1 && continue
        printf 'install.sh: missing dependency: %s   (%s)\n' "$dep" "$(_pkg_hint "$dep")" >&2
        failed=1
    done
    [[ "$failed" -eq 0 ]] || exit 1
}

# ---------------------------------------------------------------------------
# Bootstrap mode: no checkout next to this script (i.e. `curl ... | bash`).
# Fetch the repo, then re-exec the checkout's own installer with --init.
# ---------------------------------------------------------------------------

# _docker_daemon_ok — is a working Docker daemon reachable?
# HEADLONG_FAKE_DOCKER=ok|down|missing fakes the answer so the menu can be
# tried by hand; headlong-init honors the same variable.
_docker_daemon_ok() {
    case "${HEADLONG_FAKE_DOCKER:-}" in
        ok) return 0 ;;
        down|missing) return 1 ;;
    esac
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# The bootstrap installer asks before it clones anything onto the host. It
# then replaces itself with the installer from that checkout. This temporary
# marker carries the first answer across that handoff so the checkout does not
# ask the same question again.
_location_offer_available() {
    [[ "${HEADLONG_INSTALL_LOCATION_CHOSEN:-0}" != "1" ]] || return 1
    [[ ! -f /.dockerenv && ! -f /run/.containerenv ]] || return 1
    (: </dev/tty) 2>/dev/null || return 1
    _docker_daemon_ok
}

# URL helpers for the local-model endpoint: replace only a loopback
# authority host, never substrings elsewhere in the URL (a host like
# mylocalhost.dev, or a path segment, must survive untouched). The same
# helpers live in bin/shellm and tools/headlong-init — this repo duplicates
# small helpers rather than sharing a lib; keep the copies identical.
_url_host() {
    local rest="${1#*://}"
    local authority="${rest%%[/?#]*}"
    local hostport="${authority##*@}"
    case "$hostport" in
        \[*\]*) hostport="${hostport#\[}"; printf '%s' "${hostport%%]*}" ;;
        *)      printf '%s' "${hostport%%:*}" ;;
    esac
}

_url_host_swap() {
    local url="$1" newhost="$2"
    local rest="${url#*://}" scheme=""
    [[ "$rest" == "$url" ]] || scheme="${url%%://*}://"
    local authority="${rest%%[/?#]*}"
    local tail="${rest#"$authority"}"
    local userinfo=""
    case "$authority" in
        *@*) userinfo="${authority%@*}@" ;;
    esac
    local hostport="${authority##*@}" port=""
    case "$hostport" in
        \[*\]:*) port=":${hostport##*:}" ;;
        \[*\])   port="" ;;
        *:*)     port=":${hostport##*:}" ;;
    esac
    printf '%s%s%s%s%s' "$scheme" "$userinfo" "$newhost" "$port" "$tail"
}

_url_is_loopback() {
    case "$(_url_host "$1")" in
        localhost|127.*|0.0.0.0|::1) return 0 ;;
    esac
    return 1
}

# The `docker run` arguments that carry the operator's environment into the
# container, NUL-delimited for the caller to read into an array: the interview
# answers are free text, so a value may contain a newline.
#
# Secrets go by NAME. `-e VAR=value` puts the value in the docker client's
# argv, where `ps` shows it to every other user on the machine for as long as
# the client runs; thinkers/_lib/common.sh forwards keys the same way for the
# same reason, and tests/test_var_secrets.sh pins the rule for shellm. Docker
# reads a name-only `-e VAR` from its own environment, so the name must be
# exported.
#
# The interview answers are not secrets and stay inline: two of them
# (HEADLONG_REPO, HEADLONG_BRANCH) are assigned by install.sh WITHOUT export,
# so a bare name would forward nothing. The one exception is HEADLONG_LOCAL_URL
# — an endpoint URL can carry user:pass@ credentials or a query token — so it
# is treated like a secret and forwarded by name (it always arrives exported,
# from the operator's own environment). This function is collected with a
# redirect, not a pipe (see _offer_docker_install), so the export persists to
# where `docker run` reads it.
_docker_forward_args() {
    local var
    for var in ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY \
               OPENCODE_API_KEY LLM_API_KEY HEADLONG_LOCAL_API_KEY; do
        if [[ -n "${!var:-}" ]]; then
            export "${var?}"
            printf '%s\0%s\0' "-e" "$var"
        fi
    done
    if [[ -n "${HEADLONG_LOCAL_URL:-}" ]]; then
        # The installer receiving the URL runs inside the full Headlong
        # container, where localhost names that container. Use Docker's
        # hostname for a model server running on the host.
        if _url_is_loopback "$HEADLONG_LOCAL_URL"; then
            HEADLONG_LOCAL_URL=$(_url_host_swap "$HEADLONG_LOCAL_URL" host.docker.internal)
        fi
        export HEADLONG_LOCAL_URL
        printf '%s\0%s\0' "-e" "HEADLONG_LOCAL_URL"
    fi
    # (LLM_PROVIDER itself travels inside the state .env, which the
    # container's init re-persists; exporting it here would also pin it for
    # the whole container, which the operator did not ask for.)
    for var in HEADLONG_IDENTITY_NAME HEADLONG_IDENTITY_VIBE HEADLONG_IDENTITY_FOCUS \
               HEADLONG_IDENTITY_USER HEADLONG_OPERATOR_NAME HEADLONG_REPO HEADLONG_BRANCH \
               HEADLONG_PROVIDER HEADLONG_LOCAL_MODEL; do
        if [[ -n "${!var:-}" ]]; then
            printf '%s\0%s\0' "-e" "$var=${!var}"
        fi
    done
}

# _offer_docker_install — with a working Docker daemon and a human at a tty,
# offer to keep the whole agent inside a Docker container (the flow that
# docs/install.md calls the Docker one-liner) instead of installing on the
# host. Returns 0 to continue the host install; the container paths exit or
# exec and never return.
_offer_docker_install() {
    local reply=""
    cat >/dev/tty <<'EOF'
Docker is installed and running. Where should your agent live?

  1) Fully inside a Docker container. Nothing is installed on this
     machine, and everything the agent does stays in the container.
  2) On this machine. The tools go to ~/.local/bin, and the agent's
     shell commands still run sandboxed in Docker.
  3) DANGEROUSLY on this machine with NO sandbox (NOT RECOMMENDED).

EOF
    while :; do
        printf 'Choice [1]: ' >/dev/tty
        IFS= read -r reply </dev/tty || return 0
        case "$reply" in
            ""|1) break ;;
            2)    return 0 ;;
            3)
                cat >/dev/tty <<'EOF'

EVERY shell command your agent writes will run DIRECTLY ON THIS MACHINE,
as your user, with access to your files, with no sandbox. Headlong agents
run continuously and unattended. NOT RECOMMENDED.

EOF
                printf 'Type "yes" to DANGEROUSLY continue without a sandbox (anything else goes back): ' >/dev/tty
                IFS= read -r reply </dev/tty || return 0
                if [[ "$reply" == "yes" ]]; then
                    # headlong-init's gate honors this as an explicit, sticky
                    # choice and records it in the state .env.
                    export HEADLONG_UNSANDBOXED=1
                    return 0
                fi
                ;;
            *)    echo 'Please answer 1, 2, or 3.' >/dev/tty ;;
        esac
    done

    # An agent container already exists: that IS the install. Go back in
    # instead of failing on the taken name.
    if docker inspect --type container headlong >/dev/null 2>&1; then
        cat <<'EOF'

A container named 'headlong' already exists, so your agent lives there.
Dropping you into it (type exit to leave; the agent keeps running).
To update the agent, re-run the installer inside the container:
  curl -fsSL https://headlong.ai/install.sh | bash
EOF
        docker start headlong >/dev/null 2>&1 || true
        exec docker exec -it headlong bash -l </dev/tty
    fi

    # Forward a key and interview answers already in the environment, so the
    # in-container installer does not re-ask for what the operator has set.
    # A redirected function call, not process substitution: the helper's
    # exports must land in THIS shell, because docker fills a bare `-e VAR`
    # from the client's own environment.
    local -a fwd=()
    local line fwd_tmp
    fwd_tmp=$(mktemp)
    _docker_forward_args > "$fwd_tmp"
    while IFS= read -r -d '' line; do
        fwd+=("$line")
    done < "$fwd_tmp"
    rm -f "$fwd_tmp"

    echo
    echo "==> Starting your agent in a Docker container named 'headlong'"
    echo "    Dash: http://localhost:8080 once it is up. Get back in later with:"
    echo "    docker exec -it headlong bash -l"
    echo
    local rc=0
    docker run -it --name headlong --restart unless-stopped -p 8080:8080 \
        --add-host "host.docker.internal:host-gateway" \
        ${fwd[@]+"${fwd[@]}"} buildpack-deps:curl \
        bash -c 'curl -fsSL https://headlong.ai/install.sh | bash; exec bash' </dev/tty || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        cat <<'EOF'

You left the container shell; the agent keeps running in the background.
  docker exec -it headlong bash -l   back into the agent's world
  docker stop headlong               pause everything
  docker start headlong              resume
  docker rm -f headlong              delete the agent and its whole world
EOF
        exit 0
    fi
    echo "install.sh: the Docker run failed (exit $rc)." >&2
    echo "If the name or port 8080 is taken, remove the half-made container with" >&2
    echo "  docker rm -f headlong" >&2
    echo "and re-run the installer. Answer 2 to install on this machine instead." >&2
    exit "$rc"
}

_bootstrap_and_reexec() {
    _require_deps git curl jq

    cat <<'EOF'

Headlong installer. At any time, from any shell:
  read-only status:  curl -fsSL https://headlong.ai/status.sh | bash
  uninstall:         curl -fsSL https://headlong.ai/uninstall.sh | bash

EOF
    local app_dir="$HEADLONG_HOME/app"
    # Offer the whole-agent-in-Docker menu to a human at a tty with a working
    # daemon, outside a container, as long as no agent exists yet. A leftover
    # checkout alone (an install aborted before an identity was created) does
    # not count as a decision; only a completed install skips the menu.
    if [[ ! -e "$app_dir/.identities/default" ]] && _location_offer_available; then
        _offer_docker_install
        export HEADLONG_INSTALL_LOCATION_CHOSEN=1
    fi
    if [[ -d "$app_dir/.git" ]]; then
        echo "==> Updating existing checkout at $app_dir"
        if ! git -C "$app_dir" pull --ff-only origin "$HEADLONG_BRANCH"; then
            echo "install.sh: warning: could not update $app_dir; installing from what's there" >&2
        fi
    else
        echo "==> Cloning $HEADLONG_REPO ($HEADLONG_BRANCH) to $app_dir"
        mkdir -p "$HEADLONG_HOME"
        git clone --branch "$HEADLONG_BRANCH" "$HEADLONG_REPO" "$app_dir"
    fi
    echo
    exec bash "$app_dir/install.sh" --symlinks --init "$@"
}

# ---------------------------------------------------------------------------
# Checkout-mode pieces
# ---------------------------------------------------------------------------

_usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Installs Headlong's tools from bin/ and tools/ to a directory on your PATH,
plus the core skills (~/.skills/core-skills), the bundled thinker templates
(~/.headlong-thinkers), and the Rust TUI if cargo is available.

Options:
  --prefix DIR   Install directory (default: ~/.local/bin)
  --symlinks     Create symlinks instead of copies (edits take effect without reinstalling)
  --init         After installing, run `headlong-init` to bootstrap a first
                 identity and start the local dash (the curl|bash one-liner
                 does this by default)
  --uninstall    Remove Headlong from this machine (runs uninstall.sh; see
                 uninstall.sh --help for its options)
  -h, --help     Show this help

Environment variables:
  PREFIX         Same as --prefix
  SYMLINKS=1     Same as --symlinks
  HEADLONG_HOME  Headlong state directory (default: ~/.headlong)

Examples:
  ./install.sh                          # copy to ~/.local/bin
  ./install.sh --symlinks               # symlink to ~/.local/bin
  ./install.sh --prefix /usr/local/bin  # copy to /usr/local/bin (may need sudo)
  PREFIX=~/bin SYMLINKS=1 ./install.sh  # symlink to ~/bin
EOF
}

_install_tools() {
    local tool dir
    if [[ "$SYMLINKS" -eq 1 ]]; then
        echo "==> Linking tools into $PREFIX"
    else
        echo "==> Installing tools into $PREFIX"
    fi
    for tool in "${TOOLS[@]}"; do
        dir=bin
        [[ -f "tools/$tool" ]] && dir=tools
        if [[ "$SYMLINKS" -eq 1 ]]; then
            ln -sf "$(pwd)/$dir/$tool" "$PREFIX/$tool"
            echo "  Linked $tool → $PREFIX/$tool"
        else
            cp "$dir/$tool" "$PREFIX/$tool"
            chmod +x "$PREFIX/$tool"
            echo "  Installed $tool → $PREFIX/$tool"
        fi
    done
}

_install_tui() {
    [[ -d "tui" ]] || return 0
    if ! command -v cargo &>/dev/null; then
        echo "Warning: cargo not found, skipping TUI tools" >&2
        return 0
    fi
    local tui_dir name local_bin
    for tui_dir in tui/*/; do
        [[ -f "${tui_dir}Cargo.toml" ]] || continue
        name=$(basename "$tui_dir")
        printf '==> Building the %s TUI (cargo, release build)\n' "$name"
        (cd "$tui_dir" && cargo build --release --quiet) || {
            printf 'Warning: failed to build %s (skipping)\n' "$name" >&2
            continue
        }
        local_bin="${tui_dir}target/release/$name-tui"
        [[ -f "$local_bin" ]] || local_bin="${tui_dir}target/release/$name"
        if [[ -f "$local_bin" ]]; then
            cp "$local_bin" "$PREFIX/$(basename "$local_bin")"
            codesign --force --sign - "$PREFIX/$(basename "$local_bin")" 2>/dev/null || true
            echo "  Installed $(basename "$local_bin") → $PREFIX/$(basename "$local_bin")"
        fi
    done
}

_install_skills() {
    local skills_prefix="${HOME}/.skills/core-skills"
    mkdir -p "$skills_prefix"
    local skill_dir name
    for skill_dir in skills/*/; do
        [[ -f "${skill_dir}SKILL.md" ]] || continue
        name=$(basename "$skill_dir")
        if [[ "$SYMLINKS" -eq 1 ]]; then
            ln -sfn "$(pwd)/$skill_dir" "$skills_prefix/$name"
        else
            rm -rf "${skills_prefix:?}/$name"
            cp -R "$skill_dir" "$skills_prefix/$name"
        fi
    done
    echo "==> Installed core skills → $skills_prefix"
}

_install_thinkers() {
    [[ -d "thinkers" ]] || return 0
    local thinkers_prefix="${HOME}/.headlong-thinkers"
    mkdir -p "$thinkers_prefix"
    local td name
    if [[ "$SYMLINKS" -eq 1 ]]; then
        for td in thinkers/*/; do
            [[ -d "$td" ]] || continue
            ln -sfn "$(pwd)/$td" "$thinkers_prefix/$(basename "$td")"
        done
        touch "$thinkers_prefix/.use-symlinks"
    else
        for td in thinkers/*/; do
            [[ -d "$td" ]] || continue
            name=$(basename "$td")
            rm -rf "${thinkers_prefix:?}/$name"
            cp -R "$td" "$thinkers_prefix/$name"
        done
        rm -f "$thinkers_prefix/.use-symlinks"
    fi
    # Prune catalog entries for thinkers no longer in the repo, so a thinker
    # that was deleted from thinkers/ doesn't linger here (as a dangling
    # symlink or stale copy) and get resurrected into identities on the next
    # bootstrap. -e || -L catches both live entries and dangling symlinks.
    local entry
    for entry in "$thinkers_prefix"/*; do
        [[ -e "$entry" || -L "$entry" ]] || continue
        name=$(basename "$entry")
        if [[ ! -d "thinkers/$name" ]]; then
            rm -rf "${thinkers_prefix:?}/$name"
            echo "  Pruned stale thinker template → $name"
        fi
    done
    echo "==> Installed thinker templates → $thinkers_prefix"
}

# PATH: make sure the tools are reachable — for this process (so --init can
# chain into headlong-init) and, with consent, for future shells.
# A same-named system binary in a dir BEFORE $PREFIX silently shadows the tool
# we just installed (macOS ships /usr/sbin/chat, /usr/bin/view). Verify each
# installed tool actually resolves to OUR copy; warn if not. Install still
# succeeded — PATH order is the user's to fix — so this warns, never fails.
_warn_shadowed() {
    local tool resolved shadowed=()
    for tool in "${TOOLS[@]}"; do
        [[ -x "$PREFIX/$tool" ]] || continue
        resolved=$(command -v "$tool" 2>/dev/null) || resolved=""
        if [[ -n "$resolved" ]] \
           && [[ "$(realpath "$resolved" 2>/dev/null)" != "$(realpath "$PREFIX/$tool" 2>/dev/null)" ]]; then
            shadowed+=("$tool → $resolved")
        fi
    done
    [[ "${#shadowed[@]}" -eq 0 ]] && return 0
    echo
    echo "Warning: $PREFIX is on your PATH but behind a dir with same-named"
    echo "binaries, so these tools are shadowed by other programs:"
    printf '  %s\n' "${shadowed[@]}"
    echo "Move $PREFIX ahead of the system dirs (e.g. /usr/sbin) in your shell rc:"
    echo "  export PATH=\"$PREFIX:\$PATH\""
}

_ensure_path() {
    case ":$PATH:" in
        *":$PREFIX:"*) _warn_shadowed; return 0 ;;
    esac
    export PATH="$PREFIX:$PATH"
    # Tell headlong-init (exec'd below) that the calling shell does NOT have
    # $PREFIX on its PATH yet, so it can hand the user a shell that does.
    export HEADLONG_PATH_ADDED="$PREFIX"
    local path_line="export PATH=\"$PREFIX:\$PATH\"" rc="" reply=""
    case "$(basename "${SHELL:-}")" in
        zsh)  rc="$HOME/.zshrc" ;;
        bash)
            # macOS terminals open login shells, which read ~/.bash_profile
            # and skip ~/.bashrc unless the profile sources it.
            if [[ "$(uname -s)" == Darwin ]]; then rc="$HOME/.bash_profile"; else rc="$HOME/.bashrc"; fi ;;
    esac
    # In a container (throwaway env), don't ask — just persist the PATH.
    local in_container=0
    [[ -f /.dockerenv || -f /run/.containerenv ]] && in_container=1
    if [[ -n "$rc" && "$in_container" -eq 1 ]]; then
        grep -qxF "$path_line" "$rc" 2>/dev/null || printf '\n%s\n' "$path_line" >> "$rc"
        echo "==> Added $PREFIX to PATH in $rc (container — no prompt)."
        export HEADLONG_RC_FILE="$rc"
    elif [[ -n "$rc" ]] && (: </dev/tty) 2>/dev/null; then
        echo
        printf 'Add %s to your PATH in %s? [Y/n] ' "$PREFIX" "$rc" >/dev/tty
        IFS= read -r reply </dev/tty || true
        if [[ ! "$reply" =~ ^[Nn] ]]; then
            grep -qxF "$path_line" "$rc" 2>/dev/null || printf '\n%s\n' "$path_line" >> "$rc"
            echo "Added to $rc (takes effect in new shells)."
            export HEADLONG_RC_FILE="$rc"
        fi
        echo
    else
        echo
        echo "Warning: $PREFIX is not on your PATH."
        echo "Add this line to your shell rc (~/.zshrc, ~/.bashrc, etc.):"
        echo "  $path_line"
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd)"
    if [[ ! -f "$script_dir/bin/shellm" ]]; then
        _bootstrap_and_reexec "$@"
    fi
    cd "$script_dir"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --symlinks) SYMLINKS=1; shift ;;
            --prefix)   PREFIX="${2:?--prefix requires a path}"; shift 2 ;;
            --init)     RUN_INIT=1; shift ;;
            --no-init)  RUN_INIT=0; shift ;;
            --uninstall) shift; exec bash "$script_dir/uninstall.sh" "$@" ;;
            --help|-h)  _usage; exit 0 ;;
            *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
        esac
    done

    # A from-scratch `install.sh --init` in a checkout is the same decision
    # the one-liner makes: container or this machine. Offer it when nothing
    # has been installed yet; an existing identity (or no tty / no Docker)
    # keeps the plain checkout-mode behavior.
    if [[ "$RUN_INIT" -eq 1 && ! -e "$HEADLONG_HOME/app/.identities/default" \
            && ! -e "$script_dir/.identities/default" ]] \
            && _location_offer_available; then
        # The container path curls the PUBLIC installer, which would install
        # upstream main — not the code being installed right now. Default the
        # forwarded repo/branch to this checkout's own origin and branch so
        # choice 1 runs the same code (an operator-exported HEADLONG_REPO
        # still wins).
        if [[ -z "$HEADLONG_REPO_OPERATOR_SET" ]] && git -C "$script_dir" rev-parse --git-dir >/dev/null 2>&1; then
            local origin_url branch_name
            origin_url=$(git -C "$script_dir" remote get-url origin 2>/dev/null || true)
            branch_name=$(git -C "$script_dir" branch --show-current 2>/dev/null || true)
            # The clone happens inside a fresh container with no SSH keys,
            # so only an http(s) URL can work there. Rewrite the common SSH
            # forms; a local path or anything else falls back to upstream —
            # with a warning, so choice 1 is an informed one.
            case "$origin_url" in
                http://*|https://*) ;;
                ssh://git@*)
                    origin_url="https://${origin_url#ssh://git@}"
                    ;;
                git@*:*)
                    origin_url="${origin_url#git@}"
                    origin_url="https://${origin_url/://}"
                    ;;
                *)
                    if [[ -n "$origin_url" ]]; then
                        echo "note: this checkout's origin ($origin_url) cannot be cloned from inside a container;" >&2
                        echo "      the container choice below would install upstream main instead (export HEADLONG_REPO to override)." >&2
                    fi
                    origin_url=""
                    ;;
            esac
            if [[ -n "$origin_url" && -n "$branch_name" ]]; then
                HEADLONG_REPO="$origin_url"
                HEADLONG_BRANCH="$branch_name"
                export HEADLONG_REPO HEADLONG_BRANCH
            fi
        fi
        _offer_docker_install
    fi
    unset HEADLONG_INSTALL_LOCATION_CHOSEN

    _require_deps jq curl python3

    mkdir -p "$PREFIX"
    _install_tools

    # Record where the checkout lives so tools installed as copies (not
    # symlinks) can still find repo assets (web/, identities/, thinkers/).
    mkdir -p "$HEADLONG_HOME"
    printf '%s\n' "$(pwd)" > "$HEADLONG_HOME/app_dir"

    _install_tui
    _install_skills
    _install_thinkers
    _ensure_path

    if [[ "$RUN_INIT" -eq 1 ]]; then
        echo
        exec "$PREFIX/headlong-init"
    fi
}

main "$@"
