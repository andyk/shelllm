#!/usr/bin/env bash
# tests/test_uninstall.sh — uninstall.sh reverses the one-liner install.
#
# Usage: tests/test_uninstall.sh
#
# Builds a one-liner-shaped install under a throwaway HOME (a local clone of
# this repo at $HOME/.headlong/app, symlink-installed into $HOME/.local/bin,
# an identity, a PATH line in .bashrc), then:
#   1. --dry-run lists everything and changes nothing.
#   2. --yes --no-stop removes the state home, tool links (incl. the `ada`
#      persona link), skills, thinker templates and the PATH line; the
#      identities land in ~/headlong-identities-backup-*; a second run says
#      there is nothing to do.
#   3. --delete-identities leaves no backup.
#   4. From a user-owned checkout (not under the state home) the checkout
#      and its .identities are left alone.
#   5. uninstall.sh's embedded TOOLS list matches install.sh's arrays.
#   6. install.sh --uninstall delegates (--help round-trips).
#
# Processes are never touched (--no-stop): process matching is machine-wide
# and a real agent may be running next to this test.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

# --- 5. tool lists agree -----------------------------------------------------
eval "$(grep -E '^(BIN|AUX)_TOOLS=' "$REPO/install.sh")"
INSTALL_LIST=$(printf '%s\n' "${BIN_TOOLS[@]}" "${AUX_TOOLS[@]}" headlong-tui | sort)
# eval, not `source <(...)`: empty under bash 3.2 (macOS /bin/bash).
UNINSTALL_LIST=$(bash -c 'eval "$(sed -n "/^TOOLS=(/,/)/p" "$1")"; printf "%s\n" "${TOOLS[@]}" | sort' _ "$REPO/uninstall.sh")
check "uninstall.sh TOOLS == install.sh BIN+AUX+headlong-tui" test "$INSTALL_LIST" = "$UNINSTALL_LIST"

# --- fixture: a one-liner-shaped install ---------------------------------
make_install() {  # make_install <home>
    local home="$1" app="$1/.headlong/app"
    mkdir -p "$home/.headlong" "$home/.local/bin"
    git clone -q --local "$REPO" "$app" 2>/dev/null || { bad "local clone"; return 1; }
    # Exercise the working-tree inventory too, before changes are committed.
    cp "$REPO/install.sh" "$app/install.sh"
    rm -rf "$app/tui"   # no cargo build in a test
    ( cd "$app" && HOME="$home" HEADLONG_HOME="$home/.headlong" PREFIX="$home/.local/bin" \
        bash install.sh --symlinks --no-init >/dev/null 2>&1 ) || { bad "install.sh --symlinks"; return 1; }
    # an identity + the persona name link headlong-init would make
    ( cd "$app" && HOME="$home" PATH="$app/bin:$app/tools:$PATH" identity new ada --default >/dev/null 2>&1 ) || { bad "identity new"; return 1; }
    ln -s "$home/.local/bin/persona" "$home/.local/bin/ada"
    printf 'export PATH="%s/.local/bin:$PATH"\n' "$home" > "$home/.bashrc"
    printf 'alias ll="ls -l"\n' >> "$home/.bashrc"
    return 0
}

H1="$WORK/h1"
make_install "$H1" || exit 1
check "fixture: tools linked"            test -L "$H1/.local/bin/shellm"
check "fixture: optional adapter linked" test -L "$H1/.local/bin/responses-ws"
check "fixture: persona link"            test -L "$H1/.local/bin/ada"
check "fixture: skills"                  test -d "$H1/.skills/core-skills"
check "fixture: thinker templates"       test -d "$H1/.headlong-thinkers"
check "fixture: identity"                test -d "$H1/.headlong/app/.identities/ada"

run_uninstall() {  # run_uninstall <home> args...
    local home="$1"; shift
    HOME="$home" HEADLONG_HOME="$home/.headlong" PREFIX="$home/.local/bin" bash "$REPO/uninstall.sh" "$@"
}

# --- 1. dry run --------------------------------------------------------------
out=$(run_uninstall "$H1" --dry-run --no-stop 2>&1); rc=$?
check "dry-run exits 0"                          test "$rc" -eq 0
check "dry-run lists the checkout"               grep -q "$H1/.headlong/app   (the checkout)" <<<"$out"
check "dry-run lists the state home"             grep -q "$H1/.headlong   (.env" <<<"$out"
check "dry-run counts tool links"                grep -qE '[0-9]+ tool link\(s\)/copies in ' <<<"$out"
check "dry-run lists skills + thinkers"          bash -c 'grep -q "/.skills/core-skills" <<<"$1" && grep -q "/.headlong-thinkers" <<<"$1"' _ "$out"
check "dry-run lists the PATH line + rc"         grep -q "the PATH line for $H1/.local/bin in: $H1/.bashrc" <<<"$out"
check "dry-run lists the identity"               grep -qE '^    ada$' <<<"$out"
check "dry-run says backup destination"          grep -q 'will be moved to .*/headlong-identities-backup-' <<<"$out"
check "dry-run says nothing changed"             grep -q 'Dry run: nothing changed' <<<"$out"
check "dry-run: state home still there"          test -d "$H1/.headlong/app/.identities/ada"
check "dry-run: links still there"               test -L "$H1/.local/bin/shellm"

# no tty, no --yes: refuses
out=$(run_uninstall "$H1" --no-stop </dev/null 2>&1); rc=$?
check "no tty + no --yes refuses (rc 1)"         test "$rc" -eq 1
check "no tty + no --yes says --yes"             grep -q -- '--yes' <<<"$out"
check "refusal changed nothing"                  test -L "$H1/.local/bin/shellm"

# --- 2. the real thing ---------------------------------------------------------
out=$(run_uninstall "$H1" --yes --no-stop 2>&1); rc=$?
check "uninstall --yes exits 0"                  test "$rc" -eq 0
check "state home gone"                          test ! -e "$H1/.headlong"
check "tool links gone"                          test ! -e "$H1/.local/bin/shellm" -a ! -L "$H1/.local/bin/shellm"
check "optional adapter link gone"               test ! -e "$H1/.local/bin/responses-ws" -a ! -L "$H1/.local/bin/responses-ws"
check "persona link gone"                        test ! -L "$H1/.local/bin/ada"
check "all our entries gone from prefix"         bash -c '[[ -z "$(ls -A "$1" 2>/dev/null)" ]]' _ "$H1/.local/bin"
check "skills gone"                              test ! -e "$H1/.skills/core-skills"
check "thinker templates gone"                   test ! -e "$H1/.headlong-thinkers"
check "PATH line removed from .bashrc"           bash -c '! grep -q "/.local/bin" "$1"' _ "$H1/.bashrc"
check "other .bashrc lines kept"                 grep -q 'alias ll=' "$H1/.bashrc"
BK=$(ls -d "$H1"/headlong-identities-backup-* 2>/dev/null | head -1)
check "identities backed up"                     test -d "$BK/ada"
check "backup keeps the identity files"          test -f "$BK/ada/info.txt"
check "output names the backup + rm hint"        bash -c 'grep -q "Identities backed up to:  $2" <<<"$1" && grep -qF "rm -rf '"'"'$2'"'"'" <<<"$1"' _ "$out" "$BK"
check "output says uninstalled"                  grep -q 'Headlong is uninstalled' <<<"$out"
out=$(run_uninstall "$H1" --yes --no-stop 2>&1); rc=$?
check "second run: nothing to do, rc 0"          bash -c '[[ "$1" -eq 0 ]] && grep -q "Nothing to do" <<<"$2"' _ "$rc" "$out"

# --- 3. --delete-identities ----------------------------------------------
H2="$WORK/h2"
make_install "$H2" || exit 1
out=$(run_uninstall "$H2" --yes --no-stop --delete-identities 2>&1); rc=$?
check "--delete-identities exits 0"              test "$rc" -eq 0
check "--delete-identities: no backup"           bash -c '! ls -d "$1"/headlong-identities-backup-* >/dev/null 2>&1' _ "$H2"
check "--delete-identities: state home gone"     test ! -e "$H2/.headlong"

# --- 4. user-owned checkout is left alone --------------------------------------
H3="$WORK/h3"; CLONE="$WORK/myclone"
mkdir -p "$H3/.local/bin"
git clone -q --local "$REPO" "$CLONE" 2>/dev/null || { bad "clone for h3"; exit 1; }
cp "$REPO/install.sh" "$CLONE/install.sh"
rm -rf "$CLONE/tui"
( cd "$CLONE" && HOME="$H3" HEADLONG_HOME="$H3/.headlong" PREFIX="$H3/.local/bin" bash install.sh --symlinks --no-init >/dev/null 2>&1 ) || { bad "install from own clone"; exit 1; }
( cd "$CLONE" && HOME="$H3" PATH="$CLONE/bin:$CLONE/tools:$PATH" identity new bob --default >/dev/null 2>&1 ) || { bad "identity new bob"; exit 1; }
check "h3 fixture: app_dir points at the clone"  grep -qx "$CLONE" "$H3/.headlong/app_dir"
out=$(run_uninstall "$H3" --dry-run --no-stop 2>&1)
check "own clone: dry-run says it stays"         grep -q "your own checkout at $CLONE, and the .identities inside it, stay in place" <<<"$out"
check_not "own clone: no identities section"    grep -q "Your agent's identities" <<<"$out"
out=$(run_uninstall "$H3" --yes --no-stop 2>&1); rc=$?
check "own clone: uninstall exits 0"             test "$rc" -eq 0
check "own clone: clone still there"             test -f "$CLONE/bin/shellm"
check "own clone: its identity untouched"        test -d "$CLONE/.identities/bob"
check "own clone: no backup made"                bash -c '! ls -d "$1"/headlong-identities-backup-* >/dev/null 2>&1' _ "$H3"
check "own clone: state home gone"               test ! -e "$H3/.headlong"
check "own clone: links gone"                    bash -c '[[ -z "$(ls -A "$1" 2>/dev/null)" ]]' _ "$H3/.local/bin"

# --- 7. more than 6 matching processes must not kill the listing ------------------
# (printf | head -6 used to EPIPE the printf builtin; under pipefail + set -e the
# script died silently right after printing the list.) Fake dash-shaped argv via
# exec -a; dry-run only lists, nothing is signalled.
fake_pids=()
for i in 1 2 3 4 5 6 7 8; do
    ( exec -a "uv run --project /fake$i/app/web headlong-web /fake$i/app" sleep 60 ) & fake_pids+=("$!")
done
sleep 0.5
out=$(run_uninstall "$H3" --dry-run 2>&1); rc=$?
kill "${fake_pids[@]}" 2>/dev/null; wait "${fake_pids[@]}" 2>/dev/null
check ">6 processes: dry-run exits 0"          test "$rc" -eq 0
check ">6 processes: list is trimmed"          grep -qE '^  \.\.\. and [0-9]+ more$' <<<"$out"
check ">6 processes: full-list hint shown"     grep -q 'Full list:' <<<"$out"
check ">6 processes: reaches the file plan"    grep -q 'Dry run: nothing changed' <<<"$out"

# --- 6. install.sh --uninstall delegates ----------------------------------------
check "install.sh --uninstall --help shows uninstall usage" bash -c 'cd "$1" && bash install.sh --uninstall --help | grep -q "^Usage: uninstall.sh"' _ "$REPO"
check "uninstall.sh --help exits 0"              bash "$REPO/uninstall.sh" --help
check_not "unknown option is an error"           bash "$REPO/uninstall.sh" --bogus

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
