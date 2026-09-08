#!/usr/bin/env bash
# tests/smoke_install.sh — smoke-test install.sh both ways it is used.
#
# Usage: tests/smoke_install.sh
#
# Runs entirely inside throwaway HOME directories, so it never touches your
# real ~/.headlong, ~/.local/bin, ~/.skills or ~/.headlong-thinkers.
#
#   1. Checkout mode: `./install.sh --prefix ...` from this working tree,
#      copies (not symlinks). Every tool install.sh lists must land in PREFIX,
#      be executable, and answer `--help` with exit 0. The Python CLIs
#      (headlong-web, the bridges) are only exercised if `uv` is on PATH,
#      since their --help has to sync a venv first.
#
#   2. One-liner mode: the `curl ... | bash -s -- <args>` path. install.sh is
#      piped into bash from an empty directory, with HEADLONG_REPO pointed at
#      a local clone of this repo, so it bootstraps (clone + re-exec with
#      --symlinks) without the network. `--no-init` keeps it from chaining
#      into the interactive headlong-init. This tests the last COMMIT, not
#      uncommitted edits (it clones).
#
# Note: install.sh builds the Rust TUI when cargo is on PATH, so locally the
# checkout-mode step can take a minute on a cold target/. CI runs this in a
# bare Ubuntu container (no cargo), which is also the "fresh box" story the
# one-liner is written for.

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
section() { printf '\n--- %s\n' "$1"; }

# The tool list is install.sh's source of truth; pull the two arrays out of it.
eval "$(grep -E '^(BIN|AUX)_TOOLS=' "$REPO/install.sh")"
TOOLS=("${BIN_TOOLS[@]}" "${AUX_TOOLS[@]}")
PY_TOOLS=(headlong-web headlong-slack-bridge headlong-telegram-bridge responses-ws)

is_py_tool() { local t; for t in "${PY_TOOLS[@]}"; do [[ "$t" == "$1" ]] && return 0; done; return 1; }

have_uv=0
command -v uv >/dev/null 2>&1 && have_uv=1
[[ "$have_uv" -eq 1 ]] || echo "note: uv not on PATH; skipping --help for ${PY_TOOLS[*]}"

# Run a tool's --help in a sandboxed HOME. Python tools need uv on PATH, and
# bash tools must not find state from the real HOME.
help_ok() {
    local prefix="$1" home="$2" tool="$3"
    HOME="$home" HEADLONG_HOME="$home/.headlong" PATH="$prefix:$PATH" \
        "$prefix/$tool" --help </dev/null >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
section "checkout mode (copies)"
# ---------------------------------------------------------------------------
H1="$WORK/home1"; P1="$H1/.local/bin"
mkdir -p "$H1"
log1="$WORK/install1.log"
if (cd "$REPO" && HOME="$H1" HEADLONG_HOME="$H1/.headlong" SHELL=/bin/bash \
        bash ./install.sh --prefix "$P1" >"$log1" 2>&1); then
    ok "install.sh --prefix exits 0"
else
    bad "install.sh --prefix exits 0" "see $log1"; sed 's/^/    /' "$log1"
fi

for t in "${TOOLS[@]}"; do
    check "installed: $t"       test -x "$P1/$t"
    check "not a symlink: $t"   test ! -L "$P1/$t"
done
check "app_dir records the checkout" \
    test "$(cat "$H1/.headlong/app_dir" 2>/dev/null)" = "$REPO"
check "core skills installed" \
    test -n "$(ls -A "$H1/.skills/core-skills" 2>/dev/null)"
for td in "$REPO"/thinkers/*/; do
    name=$(basename "$td")
    check "thinker template copied: $name" test -d "$H1/.headlong-thinkers/$name"
done
check "thinker templates are copies (no .use-symlinks)" \
    test ! -e "$H1/.headlong-thinkers/.use-symlinks"

for t in "${TOOLS[@]}"; do
    if is_py_tool "$t" && [[ "$have_uv" -eq 0 ]]; then continue; fi
    # persona's --help is per-identity (`persona <name> --help`); with no
    # identity it exits 1 with a usage line, so check for that instead.
    if [[ "$t" == persona ]]; then
        check "--help: persona (no identity -> usage error)" \
            bash -c 'HOME="$2" HEADLONG_HOME="$2/.headlong" "$1/persona" --help 2>&1 </dev/null | grep -q "Usage: persona"' _ "$P1" "$H1"
        continue
    fi
    check "--help: $t" help_ok "$P1" "$H1" "$t"
done

# ---------------------------------------------------------------------------
section "one-liner mode (curl | bash -s -- --no-init)"
# ---------------------------------------------------------------------------
# A local clone stands in for github; the bootstrap clones it by branch name.
SRC="$WORK/src"
git clone -q "$REPO" "$SRC" 2>"$WORK/clone.err" \
    && git -C "$SRC" checkout -q -B smoke-under-test \
    || { bad "local source clone" "$(cat "$WORK/clone.err")"; }

H2="$WORK/home2"; P2="$H2/.local/bin"; EMPTY="$WORK/empty"
mkdir -p "$H2" "$EMPTY"
log2="$WORK/install2.log"
if (cd "$EMPTY" && HOME="$H2" HEADLONG_HOME="$H2/.headlong" PREFIX="$P2" SHELL=/bin/bash \
        HEADLONG_REPO="file://$SRC" HEADLONG_BRANCH=smoke-under-test \
        bash -s -- --no-init <"$REPO/install.sh" >"$log2" 2>&1); then
    ok "piped install.sh --no-init exits 0"
else
    bad "piped install.sh --no-init exits 0" "see $log2"; sed 's/^/    /' "$log2"
fi

APP="$H2/.headlong/app"
check "bootstrap cloned the repo to \$HEADLONG_HOME/app" test -d "$APP/.git"
check "clone is on the requested branch" \
    test "$(git -C "$APP" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "smoke-under-test"
check "bootstrap log mentions the clone" grep -q "Cloning" "$log2"
for t in "${TOOLS[@]}"; do
    check "symlinked: $t" test -L "$P2/$t"
done
check "symlinks resolve into the app checkout" \
    bash -c '[[ "$(cd "$(dirname "$(readlink "$1")")" && pwd)" == "$2"/* ]]' _ "$P2/shellm" "$APP"
check "app_dir records the bootstrap checkout" \
    test "$(cat "$H2/.headlong/app_dir" 2>/dev/null)" = "$APP"
check "thinker templates are symlinks (.use-symlinks)" \
    test -e "$H2/.headlong-thinkers/.use-symlinks"
check "headlong-init was not started" bash -c '! grep -q "headlong-init — bootstrap" "$1"' _ "$log2"
check "--help via symlink: shellm"   help_ok "$P2" "$H2" shellm
check "--help via symlink: thinkers" help_ok "$P2" "$H2" thinkers

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
