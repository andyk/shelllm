#!/usr/bin/env bash
# test_llm_bedrock.sh - Amazon Bedrock routing, payloads, auth, and Responses SSE

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ - $2}"; }
check() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
check_not() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }

mkdir -p "$WORK/bin" "$WORK/home"
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_ARGS"

out_file=""
body=""
url=""
config=""
prev=""
for arg in "$@"; do
    case "$prev" in
        -o) out_file="$arg" ;;
        -d) body="$arg" ;;
        --config) config="$arg" ;;
    esac
    [[ "$arg" == http* ]] && url="$arg"
    prev="$arg"
done
case "$body" in
    @*) cp "${body#@}" "$PAYLOAD_OUT" ;;
esac
[[ -z "$config" ]] || cp "$config" "$SIGV4_OUT"

if [[ -n "$out_file" ]]; then
    if [[ "$url" == */model/*/invoke ]]; then
        printf '%s' '{"content":[{"type":"thinking","thinking":"considering"},{"type":"text","text":"claude ok"}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":3}}' > "$out_file"
    else
        printf '%s' '{"status":"completed","output":[{"type":"reasoning","summary":[{"type":"summary_text","text":"reasoned"}]},{"type":"message","content":[{"type":"output_text","text":"mantle "}]},{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":20,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2}}}' > "$out_file"
    fi
    printf '200'
else
    printf 'event: response.reasoning_summary_text.delta\n'
    printf 'data: {"type":"response.reasoning_summary_text.delta","delta":"reasoned"}\n\n'
    printf 'event: response.output_text.delta\n'
    printf 'data: {"type":"response.output_text.delta","delta":"mantle "}\n\n'
    printf 'event: response.output_text.delta\n'
    printf 'data: {"type":"response.output_text.delta","delta":"ok"}\n\n'
    printf 'event: response.completed\n'
    printf 'data: {"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":20,"output_tokens":5,"output_tokens_details":{"reasoning_tokens":2}}}}\n\n'
fi
EOF
chmod +x "$WORK/bin/curl"
cat > "$WORK/bin/aws" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == "configure get region --profile test-profile" ]]; then
    printf 'ap-southeast-2\n'
    exit 0
fi
if [[ "$*" == "configure export-credentials --profile test-profile --format process" ]]; then
    n=$(( $(cat "$AWS_EXPORT_COUNT" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$AWS_EXPORT_COUNT"
    printf '{"Version":1,"AccessKeyId":"PROFILEKEY%s","SecretAccessKey":"profile-secret-%s","SessionToken":"profile-session-%s"}\n' "$n" "$n" "$n"
    exit 0
fi
printf 'unexpected aws invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$WORK/bin/aws"

export PATH="$WORK/bin:$PATH"
export HEADLONG_HOME="$WORK/home"
export CURL_ARGS="$WORK/curl.args"
export PAYLOAD_OUT="$WORK/payload.json"
export SIGV4_OUT="$WORK/sigv4.conf"
export AWS_EXPORT_COUNT="$WORK/aws-export-count"
export LLM_RETRIES=0 LLM_USAGE_LEDGER=/dev/null
unset ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY OPENCODE_API_KEY
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE
unset AWS_DEFAULT_REGION HEADLONG_AWS_PROFILE_CREDENTIALS LLM_PROVIDER LLM_API_URL LLM_MODEL SHELLM_MODEL
export AWS_BEARER_TOKEN_BEDROCK="bedrock-test-token"

LLM="$REPO/bin/llm"
run_llm() { (cd "$WORK" && "$LLM" "$@"); }
reset() { : > "$CURL_ARGS"; : > "$PAYLOAD_OUT"; : > "$SIGV4_OUT"; }

# Claude uses InvokeModel and automatically takes the non-streaming path.
reset
out=$(AWS_REGION=eu-west-1 run_llm --stream -m 'bedrock/us.anthropic.claude-sonnet-4-6-v1:0' \
    --thinking --effort high 'say ok' 2>"$WORK/stderr")
check "Claude response extracted" test "$out" = "claude ok"
check "Claude model routes to Bedrock Runtime" grep -q 'bedrock-runtime.eu-west-1.amazonaws.com/model/us.anthropic.claude-sonnet-4-6-v1%3A0/invoke' "$CURL_ARGS"
check "Bedrock routing prefix is stripped" jq -e '.model == null' "$PAYLOAD_OUT"
check "Claude payload uses Bedrock Messages version" jq -e '.anthropic_version == "bedrock-2023-05-31"' "$PAYLOAD_OUT"
check "Claude payload omits stream" jq -e 'has("stream") | not' "$PAYLOAD_OUT"
check "Claude payload retains thinking and effort" jq -e '.thinking.type == "adaptive" and .output_config.effort == "high"' "$PAYLOAD_OUT"
check "Claude non-streaming cap stays within InvokeModel limit" jq -e '.max_tokens == 21333' "$PAYLOAD_OUT"
check "explicit Claude streaming explains fallback" grep -q 'binary event frames' "$WORK/stderr"
check "Claude non-streaming thinking is emitted on stderr" grep -q 'considering' "$WORK/stderr"
check "Bedrock API key is bearer auth" grep -q 'Authorization: Bearer bedrock-test-token' "$CURL_ARGS"

# Claude 4.5 predates adaptive thinking; translate effort to a fixed budget.
reset
out=$(run_llm --no-stream -m 'us.anthropic.claude-sonnet-4-5-20250929-v1:0' \
    --thinking --effort high -t 10000 'say ok' 2>"$WORK/stderr")
check "older Claude response extracted" test "$out" = "claude ok"
check "older Claude uses fixed-budget thinking" jq -e '.thinking.type == "enabled" and .thinking.budget_tokens == 8192' "$PAYLOAD_OUT"
check "older Claude drops unsupported output effort" jq -e 'has("output_config") | not' "$PAYLOAD_OUT"

# gpt-oss uses Mantle's default /v1 Responses route and streams typed SSE.
reset
out=$(run_llm -m openai.gpt-oss-120b -t 321 'say ok' 2>"$WORK/stderr")
check "Mantle gpt-oss stream extracted" test "$out" = "mantle ok"
check "Mantle reasoning summary streams on stderr" grep -q 'reasoned' "$WORK/stderr"
check "gpt-oss uses Mantle default Responses route" grep -q 'bedrock-mantle.us-east-1.api.aws/v1/responses' "$CURL_ARGS"
check_not "gpt-oss avoids first-party OpenAI route" grep -q '/openai/v1/responses' "$CURL_ARGS"
check "Responses payload uses input messages" jq -e '.model == "openai.gpt-oss-120b" and .input[0].content == "say ok"' "$PAYLOAD_OUT"
check "Responses payload streams without retention" jq -e '.stream == true and .store == false and .max_output_tokens == 321' "$PAYLOAD_OUT"

# First-party GPT models use Mantle's special /openai/v1 route.
reset
out=$(run_llm -m openai.gpt-5.6-sol --thinking high --system-prompt 'be terse' 'say ok' 2>"$WORK/stderr")
check "Mantle GPT-5.6 stream extracted" test "$out" = "mantle ok"
check "GPT-5.6 uses Mantle OpenAI Responses route" grep -q 'bedrock-mantle.us-east-1.api.aws/openai/v1/responses' "$CURL_ARGS"
check "Responses payload carries instructions and reasoning" jq -e '.instructions == "be terse" and .reasoning.effort == "high"' "$PAYLOAD_OUT"

# Non-streaming extraction scans all output items rather than assuming index 0.
reset
out=$(LLM_USAGE_FILE="$WORK/usage.json" run_llm --no-stream -m openai.gpt-5.6-sol 'say ok' 2>"$WORK/stderr")
check "non-streaming Responses output is joined" test "$out" = "mantle ok"
check "non-streaming Responses reasoning is on stderr" grep -q 'reasoned' "$WORK/stderr"
check "Responses usage is recorded" jq -e '.in_tok == 20 and .out_tok == 5 and .think_tok == 2' "$WORK/usage.json"

# Geographic/global OpenAI IDs are valid on Bedrock Runtime's Responses API.
reset
out=$(run_llm -m global.openai.gpt-5.6-sol 'say ok' 2>"$WORK/stderr")
check "runtime OpenAI stream extracted" test "$out" = "mantle ok"
check "global OpenAI ID uses Runtime Responses route" grep -q 'bedrock-runtime.us-east-1.amazonaws.com/openai/v1/responses' "$CURL_ARGS"

# Standard AWS credentials are the fallback and the secret stays off argv.
reset
unset AWS_BEARER_TOKEN_BEDROCK
export AWS_ACCESS_KEY_ID=AKIATEST AWS_SECRET_ACCESS_KEY='secret/test+value' AWS_SESSION_TOKEN='session/test+value'
out=$(run_llm --no-stream -m openai.gpt-oss-120b 'say ok' 2>"$WORK/stderr")
check "SigV4 fallback succeeds" test "$out" = "mantle ok"
check "Mantle SigV4 service is configured" grep -q 'aws:amz:us-east-1:bedrock-mantle' "$SIGV4_OUT"
check "SigV4 config contains the AWS credentials" grep -q 'AKIATEST:secret/test+value' "$SIGV4_OUT"
check "SigV4 config includes the session token" grep -q 'x-amz-security-token: session/test+value' "$SIGV4_OUT"
check_not "AWS secret is absent from curl argv" grep -q 'secret/test+value' "$CURL_ARGS"

# AWS_PROFILE resolves credential_process credentials for every llm invocation
# and supplies the profile's region when no region environment variable exists.
reset
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION AWS_DEFAULT_REGION
export AWS_PROFILE=test-profile
out=$(run_llm --no-stream -t 256 'say ok' 2>"$WORK/stderr")
check "AWS profile alone selects the Bedrock Claude default" test "$out" = "claude ok"
check "AWS profile region selects the Bedrock endpoint" grep -q 'bedrock-runtime.ap-southeast-2.amazonaws.com' "$CURL_ARGS"
check "AWS profile credentials feed curl SigV4" grep -q 'PROFILEKEY1:profile-secret-1' "$SIGV4_OUT"
check_not "profile secret is absent from curl argv" grep -q 'profile-secret-1' "$CURL_ARGS"

reset
out=$(run_llm --no-stream -m openai.gpt-oss-120b 'say ok' 2>"$WORK/stderr")
check "AWS profile works with Mantle" test "$out" = "mantle ok"
check "AWS profile is resolved again for the next call" grep -q 'PROFILEKEY2:profile-secret-2' "$SIGV4_OUT"
check "credential_process export ran once per call" test "$(cat "$AWS_EXPORT_COUNT")" = 2

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
