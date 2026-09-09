#!/usr/bin/env bash
# Copied-prefix lifecycle/optional adapter packaging, without uv or a provider.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n' "$1"; }

mkdir -p "$WORK/source" "$WORK/home" "$WORK/prefix" "$WORK/support" "$WORK/wd"
cp -R "$REPO/bin" "$REPO/tools" "$WORK/source/"
cp "$REPO/install.sh" "$WORK/source/"
cp "$REPO/uninstall.sh" "$WORK/uninstall.sh"
# An explicit dependency PATH excludes uv, cargo, and any other checkout's
# tools, even when these happen to be installed on the developer machine.
for tool in bash basename dirname pwd cp chmod mkdir rm rmdir ln readlink realpath \
    jq curl python3 sed grep uname cat mktemp date sleep wc tr head tail sort \
    cut fold find touch mv env awk; do
    path=$(command -v "$tool")
    [[ "$path" == /* ]] || path="/bin/$tool"
    ln -s "$path" "$WORK/support/$tool"
done
clean() {
    env -i HOME="$WORK/home" HEADLONG_HOME="$WORK/home/.headlong" \
        PREFIX="$WORK/prefix" PATH="$WORK/prefix:$WORK/support" SHELL=/bin/bash \
        "$@"
}
if clean bash -c '! command -v uv' && clean bash "$WORK/source/install.sh" --no-init > "$WORK/install.out" 2>&1; then
    ok "normal copy installation succeeds without uv"
else
    bad "normal copy installation succeeds without uv"
    cat "$WORK/install.out"
fi
if [[ -x "$WORK/prefix/responses-ws" && ! -L "$WORK/prefix/responses-ws" ]] \
    && cmp -s "$WORK/source/tools/responses-ws" "$WORK/prefix/responses-ws"; then
    ok "copy inventory installs the optional adapter executable unchanged"
else
    bad "copy inventory installs the optional adapter executable unchanged"
fi

rm -rf "$WORK/source"
# Extract the installed resolver, not a test reimplementation. No source tree
# or PATH fallback exists now, so this must find the installed sibling.
sed -n '/^tool_sibling_path() {/,/^}/p; /^resolve_shellm_tool_path() {/,/^}/p' \
    "$WORK/prefix/shellm" > "$WORK/resolver"
resolved=$(clean bash -c 'source "$1"; resolve_shellm_tool_path "$2" responses-ws' \
    _ "$WORK/resolver" "$WORK/prefix/shellm")
if [[ "$resolved" == "$(realpath "$WORK/prefix/responses-ws")" ]]; then
    ok "copied shellm resolves its adapter with the source checkout unavailable"
else
    bad "copied shellm resolves its adapter with the source checkout unavailable"
fi
if clean "$WORK/prefix/responses" --help > /dev/null; then
    ok "copied lifecycle CLI runs without the source checkout or uv"
else
    bad "copied lifecycle CLI runs without the source checkout or uv"
fi

# An ordinary chat completion still does not need uv. Stub only the HTTP edge.
rm "$WORK/support/curl"
cat > "$WORK/support/curl" <<'STUB'
#!/usr/bin/env bash
body='{"choices":[{"message":{"content":"chat fixture"}}]}'
out=""; prev=""
for arg in "$@"; do
    [[ "$prev" == -o ]] && out="$arg"
    prev="$arg"
done
if [[ -n "$out" ]]; then printf '%s' "$body" > "$out"; printf 200
else printf '%s' "$body"; fi
STUB
chmod +x "$WORK/support/curl"
if ( cd "$WORK/wd" && clean env LLM_PROVIDER=openai OPENAI_API_KEY=fixture-key \
    LLM_RETRIES=0 "$WORK/prefix/llm" --no-stream -m fixture-model hello ) \
    > "$WORK/chat.out" 2> "$WORK/chat.err" && grep -q 'chat fixture' "$WORK/chat.out"; then
    ok "ordinary copied chat completion does not require uv"
else
    bad "ordinary copied chat completion does not require uv"
    cat "$WORK/chat.err"
fi

if ( cd "$WORK/wd" && clean env OPENAI_API_KEY=fixture-key SHELLM_ENV=local \
    SHELLM_API_FORMAT=responses SHELLM_API_TRANSPORT=websocket SHELLM_MODEL=gpt-test \
    "$WORK/prefix/shellm" --workdir "$WORK/wd" --max-iterations 1 test ) \
    > "$WORK/ws.out" 2> "$WORK/ws.err"; then
    bad "selecting the copied WebSocket adapter without uv fails before inference"
elif grep -q 'WebSocket transport requires uv' "$WORK/ws.err"; then
    ok "selecting the copied WebSocket adapter without uv gives actionable guidance"
else
    bad "selecting the copied WebSocket adapter without uv gives actionable guidance"
    cat "$WORK/ws.err"
fi

if clean bash "$WORK/uninstall.sh" --yes --no-stop > "$WORK/uninstall.out" 2>&1 \
    && [[ ! -e "$WORK/prefix/responses-ws" && ! -e "$WORK/prefix/responses" ]]; then
    ok "standalone uninstall removes copied lifecycle and adapter executables"
else
    bad "standalone uninstall removes copied lifecycle and adapter executables"
    cat "$WORK/uninstall.out"
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
