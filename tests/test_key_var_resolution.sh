#!/usr/bin/env bash
# tests/test_key_var_resolution.sh — provider selection when a key sits in the
# wrong variable, and LLM_MAX_TOKENS coming from the environment.
#
# Usage: tests/test_key_var_resolution.sh
#
# Why: the provider is chosen from whichever *_API_KEY variable is set first,
# and the model default follows from that. A key exported into the wrong
# variable (an sk-or- OpenRouter key in OPENAI_API_KEY) therefore picked
# gpt-5.5, which detect_provider routes to api.openai.com, and the run died
# with a confusing "Incorrect API key provided". The prefix now wins, except
# where it is genuinely ambiguous (a bare sk- key is OpenAI or OpenCode).
# No network and no real daemon are touched; curl, docker and llm are stubs.
# Key fixtures below carry only the prefix that matters and are deliberately
# shaped so they cannot match a real provider pattern (GitHub push protection
# rejects fixtures that look like the genuine article).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"

WORK=$(mktemp -d)
trap 'cd /; rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }
check()     { local l="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$l"; else bad "$l"; fi; }
check_not() { local l="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$l"; else ok "$l"; fi; }

STUB="$WORK/stub"; mkdir -p "$STUB"
# docker: daemon up, everything else succeeds so no image is pulled.
printf '#!/usr/bin/env bash\ncase "${1:-}" in info) exit 0 ;; *) exit 0 ;; esac\n' > "$STUB/docker"
# llm: always fails, so init stops right after writing SHELLM_MODEL. Without a
# tty that is a single fast failure, which is all these assertions need.
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/llm"
cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "configure get region --profile test-profile" ]]; then
    printf 'us-west-2\n'
    exit 0
fi
exit 1
EOF
chmod +x "$STUB/docker" "$STUB/llm" "$STUB/aws"

APP="$WORK/app"; mkdir -p "$APP/bin" "$APP/tools"
: > "$APP/bin/shellm"

# run_init <home> [VAR=VAL ...] — headlong-init with no tty, no inherited keys.
run_init() {
    local home="$1"; shift
    mkdir -p "$home"
    env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY \
        -u OPENCODE_API_KEY -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID \
        -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN -u AWS_REGION -u AWS_DEFAULT_REGION \
        -u AWS_PROFILE -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
        -u SHELLM_MODEL -u HEADLONG_UNSANDBOXED \
        HOME="$home" HEADLONG_HOME="$home/.headlong" HEADLONG_APP_DIR="$APP" \
        HEADLONG_NO_TTY=1 HEADLONG_UNSANDBOXED=1 PATH="$STUB:$PATH" "$@" \
        bash "$REPO/tools/headlong-init" </dev/null > "$WORK/out" 2>&1
}
# --- the reported case: OpenRouter key exported as OPENAI_API_KEY ------------
run_init "$WORK/h1" OPENAI_API_KEY=sk-or-v1-EXAMPLE-NOT-A-REAL-KEY
check "misplaced sk-or- key: model follows the key, not the variable" \
    grep -qx 'SHELLM_MODEL=anthropic/claude-sonnet-4.5' "$WORK/h1/.headlong/.env"
check "misplaced sk-or- key: says which variable it should be in" \
    grep -q 'OPENROUTER_API_KEY' "$WORK/out"
check_not "misplaced sk-or- key: never defaults to an OpenAI model" \
    grep -q 'SHELLM_MODEL=gpt-' "$WORK/h1/.headlong/.env"
# The correction must outlive this process: a later persona or llm run in a
# fresh shell reads the .env, not the reconciler's exports.
check "misplaced sk-or- key: persisted under the right variable, once" \
    [ "$(grep -c '^OPENROUTER_API_KEY=' "$WORK/h1/.headlong/.env")" = 1 ]
check "misplaced sk-or- key: the state env stays private (mode 600)" \
    [ "$(stat -c %a "$WORK/h1/.headlong/.env" 2>/dev/null || stat -f %Lp "$WORK/h1/.headlong/.env")" = 600 ]

# --- a correctly placed OpenAI key is untouched ------------------------------
run_init "$WORK/h2" OPENAI_API_KEY=sk-proj-EXAMPLE-NOT-A-REAL-KEY
check "consistent OpenAI key: keeps the OpenAI default" \
    grep -qx 'SHELLM_MODEL=gpt-5.5' "$WORK/h2/.headlong/.env"
check_not "consistent OpenAI key: warns about nothing" \
    grep -qi 'prefix belongs to' "$WORK/out"

# --- a bare sk- key is OpenAI *or* OpenCode: ambiguous, so never moved -------
run_init "$WORK/h3" OPENCODE_API_KEY=sk-EXAMPLE-NOT-A-REAL-KEY
check "bare sk- in OPENCODE_API_KEY: left where it is" \
    grep -qx 'SHELLM_MODEL=opencode-go/deepseek-v4-flash' "$WORK/h3/.headlong/.env"
check_not "bare sk- in OPENCODE_API_KEY: not remapped to OpenAI" \
    grep -qi 'prefix belongs to' "$WORK/out"

# --- misplaced key alongside a correctly placed one: the right one wins ------
run_init "$WORK/h4" \
    OPENAI_API_KEY=sk-or-v1-EXAMPLE-MISPLACED-KEY \
    OPENROUTER_API_KEY=sk-or-v1-EXAMPLE-CORRECT-KEY
check "both set: picks the consistent variable" \
    grep -qx 'SHELLM_MODEL=anthropic/claude-sonnet-4.5' "$WORK/h4/.headlong/.env"

# --- an Anthropic key in the wrong slot is corrected too ---------------------
run_init "$WORK/h5" OPENAI_API_KEY=sk-ant-api03-EXAMPLE-NOT-A-REAL-KEY
check "misplaced sk-ant- key: model follows the key" \
    grep -qx 'SHELLM_MODEL=claude-sonnet-4-5-20250929' "$WORK/h5/.headlong/.env"

# --- Bedrock bearer tokens and SigV4 credentials pick the Bedrock default ----
run_init "$WORK/h8" AWS_BEARER_TOKEN_BEDROCK=BEDROCK-EXAMPLE-NOT-A-REAL-KEY
check "Bedrock API key: picks the Bedrock Claude default" \
    grep -qx 'SHELLM_MODEL=us.anthropic.claude-sonnet-4-6' "$WORK/h8/.headlong/.env"
check "Bedrock API key: key and default region persist" bash -c \
    'grep -qx "AWS_BEARER_TOKEN_BEDROCK=BEDROCK-EXAMPLE-NOT-A-REAL-KEY" "$1" && grep -qx "AWS_REGION=us-east-1" "$1"' \
    _ "$WORK/h8/.headlong/.env"

run_init "$WORK/h9" AWS_ACCESS_KEY_ID=AKIAEXAMPLE AWS_SECRET_ACCESS_KEY=EXAMPLE-NOT-A-REAL-SECRET
check "AWS credential pair: picks the Bedrock Claude default" \
    grep -qx 'SHELLM_MODEL=us.anthropic.claude-sonnet-4-6' "$WORK/h9/.headlong/.env"
check "AWS credential pair: credentials persist for later launches" bash -c \
    'grep -qx "AWS_ACCESS_KEY_ID=AKIAEXAMPLE" "$1" && grep -qx "AWS_SECRET_ACCESS_KEY=EXAMPLE-NOT-A-REAL-SECRET" "$1"' \
    _ "$WORK/h9/.headlong/.env"

run_init "$WORK/h12" AWS_PROFILE=test-profile AWS_CONFIG_FILE="$WORK/aws-config"
check "AWS profile: picks the Bedrock Claude default" \
    grep -qx 'SHELLM_MODEL=us.anthropic.claude-sonnet-4-6' "$WORK/h12/.headlong/.env"
check "AWS profile: profile and config path persist" bash -c \
    'grep -qx "AWS_PROFILE=test-profile" "$1" && grep -qx "AWS_CONFIG_FILE=$2" "$1"' \
    _ "$WORK/h12/.headlong/.env" "$WORK/aws-config"
check "AWS profile: configured region persists" \
    grep -qx 'AWS_REGION=us-west-2' "$WORK/h12/.headlong/.env"

run_init "$WORK/h10" OPENAI_API_KEY=ABSK-EXAMPLE-NOT-A-REAL-KEY
check "misplaced ABSK key: recognized and persisted as a Bedrock API key" \
    grep -qx 'AWS_BEARER_TOKEN_BEDROCK=ABSK-EXAMPLE-NOT-A-REAL-KEY' "$WORK/h10/.headlong/.env"
check "misplaced ABSK key: model follows Bedrock" \
    grep -qx 'SHELLM_MODEL=us.anthropic.claude-sonnet-4-6' "$WORK/h10/.headlong/.env"

run_init "$WORK/h11" OPENAI_API_KEY=bedrock-api-key-EXAMPLE-NOT-A-REAL-KEY
check "misplaced short-term Bedrock token: recognized as Bedrock" \
    grep -qx 'AWS_BEARER_TOKEN_BEDROCK=bedrock-api-key-EXAMPLE-NOT-A-REAL-KEY' "$WORK/h11/.headlong/.env"

# --- a stale SHELLM_MODEL pinned from the misfiled variable heals ------------
# An earlier init derived gpt-5.5 from the key sitting in OPENAI_API_KEY;
# reconciling the key must re-pin the model, or every later run keeps routing
# to the wrong provider.
mkdir -p "$WORK/h7/.headlong"
printf 'SHELLM_MODEL=gpt-5.5\n' > "$WORK/h7/.headlong/.env"
run_init "$WORK/h7" OPENAI_API_KEY=sk-or-v1-EXAMPLE-NOT-A-REAL-KEY
check "stale model from the misfiled variable: re-pinned to the key's provider" \
    grep -qx 'SHELLM_MODEL=anthropic/claude-sonnet-4.5' "$WORK/h7/.headlong/.env"

# --- bin/llm honors LLM_MAX_TOKENS from the environment ----------------------
# curl stub records the request body; llm builds it with jq before sending.
CURL_STUB="$WORK/curlstub"; mkdir -p "$CURL_STUB"
cat > "$CURL_STUB/curl" <<'EOF'
#!/usr/bin/env bash
body=""
prev=""
for a in "$@"; do
    case "$prev" in -d|--data|--data-binary|--data-raw) body="$a" ;; esac
    prev="$a"
done
case "$body" in
    "@-"|"") body="$(cat)" ;;
    @*)      body="$(cat "${body#@}")" ;;
esac
printf '%s' "$body" > "$PAYLOAD_OUT"
printf 'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
printf 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n'
printf 'data: {"type":"message_stop"}\n\n'
EOF
chmod +x "$CURL_STUB/curl"

# cd first: bin/llm loads ./.env from the cwd, so running from a checkout
# with a real .env would leak its keys into the assertion. The env -u list
# covers every var that steers provider or model resolution.
export PAYLOAD_OUT="$WORK/payload.json"
cd "$WORK" || exit 1
env -u SHELLM_MODEL -u HEADLONG_HOME -u LLM_PROVIDER -u LLM_API_URL -u LLM_MODEL \
    -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY -u OPENCODE_API_KEY \
    -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
    -u AWS_PROFILE -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
    PATH="$CURL_STUB:$PATH" LLM_RETRIES=0 \
    HOME="$WORK/h6" ANTHROPIC_API_KEY=sk-ant-test LLM_MAX_TOKENS=4242 \
    bash "$REPO/bin/llm" -m claude-sonnet-4-5-20250929 hi >/dev/null 2>&1
check "bin/llm: LLM_MAX_TOKENS from the environment reaches the request" \
    grep -q '"max_tokens":[[:space:]]*4242' "$PAYLOAD_OUT"

# A command in a loaded .env must not leak its stdout into values: pre-fix,
# the echo's output rode into LLM_MAX_TOKENS ("POLLUTION\n1234") and the
# request fell back to the model default instead of 1234.
printf 'echo POLLUTION\nLLM_MAX_TOKENS=1234\n' > "$WORK/.env"
env -u SHELLM_MODEL -u HEADLONG_HOME -u LLM_PROVIDER -u LLM_API_URL -u LLM_MODEL \
    -u OPENAI_API_KEY -u GEMINI_API_KEY -u OPENROUTER_API_KEY -u OPENCODE_API_KEY \
    -u AWS_BEARER_TOKEN_BEDROCK -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
    -u AWS_PROFILE -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE \
    -u LLM_MAX_TOKENS \
    PATH="$CURL_STUB:$PATH" LLM_RETRIES=0 \
    HOME="$WORK/h6" ANTHROPIC_API_KEY=sk-ant-test \
    bash "$REPO/bin/llm" -m claude-sonnet-4-5-20250929 hi >/dev/null 2>&1
check "bin/llm: .env stdout stays out of the values it loads" \
    grep -q '"max_tokens":[[:space:]]*1234' "$PAYLOAD_OUT"
rm -f "$WORK/.env"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
