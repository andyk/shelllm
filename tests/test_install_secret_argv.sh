#!/usr/bin/env bash
# tests/test_install_secret_argv.sh — the container install keeps API keys off
# the docker command line.
#
# install.sh forwards a key and the interview answers into the container it
# starts. A value passed as `-e VAR=value` is an argument of the docker client,
# so it is readable from `ps` by any other local user for as long as that
# process lives; tests/test_var_secrets.sh already pins the same rule for the
# shellm path, and thinkers/_lib/common.sh already forwards keys by bare name
# for the same reason. Keys therefore go by NAME, which requires them to be exported, and
# the non-secret answers stay inline because two of them (HEADLONG_REPO,
# HEADLONG_BRANCH) are assigned by install.sh without export and a bare name
# would silently forward nothing.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass=0
fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Source install.sh for its functions: drop the trailing `main "$@"`, which
# would otherwise run the installer.
sed '$ d' "$REPO/install.sh" > "$WORK/install.lib"

SECRET=sk-or-ARGVCANARY
OPENCODE_SECRET=sk-OPENCODECANARY
BEDROCK_SECRET=BEDROCK-ARGVCANARY
AWS_SECRET=AWS-SECRET-ARGVCANARY
args=$(
    export OPENROUTER_API_KEY="$SECRET"
    export OPENCODE_API_KEY="$OPENCODE_SECRET"
    export AWS_BEARER_TOKEN_BEDROCK="$BEDROCK_SECRET"
    export AWS_ACCESS_KEY_ID=AKIAARGVCANARY
    export AWS_SECRET_ACCESS_KEY="$AWS_SECRET"
    export AWS_SESSION_TOKEN=AWS-SESSION-ARGVCANARY
    export AWS_PROFILE=bedrock-profile
    export AWS_CONFIG_FILE=/tmp/aws-config
    export AWS_REGION=us-east-1
    export HEADLONG_IDENTITY_NAME=ada
    # Set, deliberately NOT exported, which is how install.sh leaves them.
    # shellcheck disable=SC2034  # read by _docker_forward_args through ${!var}
    HEADLONG_REPO=https://example.invalid/fork.git
    # shellcheck disable=SC2034  # read by _docker_forward_args through ${!var}
    HEADLONG_BRANCH=experiment
    # shellcheck disable=SC1090  # generated copy of the installer under test
    source "$WORK/install.lib"
    # Flatten the NUL delimiters here: command substitution drops NUL bytes,
    # so the records must become space-separated before capture.
    _docker_forward_args | tr '\0' ' '
)
flat=" $args "   # padded so a match at either end still has a boundary

case "$flat" in
    *"$SECRET"*) bad "no API key value on the docker command line" "found $SECRET in: $flat" ;;
    *)           ok  "no API key value on the docker command line" ;;
esac
case "$flat" in
    *"-e AWS_PROFILE "*"-e AWS_CONFIG_FILE "*) ok "AWS profile configuration is forwarded by name" ;;
    *) bad "AWS profile configuration is forwarded by name" "got: $flat" ;;
esac
case "$flat" in
    *"$BEDROCK_SECRET"*|*"$AWS_SECRET"*) bad "Bedrock credentials stay off the docker command line" "got: $flat" ;;
    *"-e AWS_BEARER_TOKEN_BEDROCK "*"-e AWS_SECRET_ACCESS_KEY "*) ok "Bedrock credentials are forwarded by name" ;;
    *) bad "Bedrock credentials are forwarded by name" "got: $flat" ;;
esac
case "$flat" in
    *"-e OPENROUTER_API_KEY "*) ok "the key is forwarded by name" ;;
    *) bad "the key is forwarded by name" "got: $flat" ;;
esac
case "$flat" in
    *"$OPENCODE_SECRET"*) bad "every provider key goes by name, not just the first" "found $OPENCODE_SECRET in: $flat" ;;
    *"-e OPENCODE_API_KEY "*) ok "every provider key goes by name, not just the first" ;;
    *) bad "every provider key goes by name, not just the first" "got: $flat" ;;
esac
case "$flat" in
    *"-e HEADLONG_IDENTITY_NAME=ada "*) ok "interview answers are still forwarded inline" ;;
    *) bad "interview answers are still forwarded inline" "got: $flat" ;;
esac
# The two the script assigns itself: a bare name would forward nothing, because
# docker reads a name-only -e from its own environment.
case "$flat" in
    *"-e HEADLONG_REPO=https://example.invalid/fork.git "*) ok "an unexported repo override still reaches the container" ;;
    *) bad "an unexported repo override still reaches the container" "got: $flat" ;;
esac
case "$flat" in
    *"-e HEADLONG_BRANCH=experiment "*) ok "an unexported branch override still reaches the container" ;;
    *) bad "an unexported branch override still reaches the container" "got: $flat" ;;
esac

# Forwarding by name only works if the variable is actually exported, so prove
# the helper leaves it that way rather than trusting that the caller did.
exported=$(
    OPENROUTER_API_KEY="$SECRET"        # set, NOT exported
    # shellcheck disable=SC1090  # generated copy of the installer under test
    source "$WORK/install.lib"
    # The caller's exact collection pattern from _offer_docker_install: a
    # redirected call plus a NUL read loop. Process substitution here would
    # confine the export to a child and forward an empty value.
    _docker_forward_args > "$WORK/fwd"
    # shellcheck disable=SC2034  # the records are drained, not inspected
    while IFS= read -r -d '' line; do :; done < "$WORK/fwd"
    export -p | grep -c '^declare -x OPENROUTER_API_KEY=' || true
)
[[ "$exported" -ge 1 ]] && ok "the key is exported, so the bare name carries a value" \
    || bad "the key is exported, so the bare name carries a value" "not exported after the call"

# With no key and no answers set, only the repo/branch defaults install.sh
# fills in are forwarded, and no key name appears at all.
none=$(
    unset OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY OPENCODE_API_KEY
    unset AWS_BEARER_TOKEN_BEDROCK AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    unset AWS_PROFILE AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE AWS_REGION AWS_DEFAULT_REGION
    unset HEADLONG_IDENTITY_NAME HEADLONG_IDENTITY_VIBE HEADLONG_IDENTITY_FOCUS
    unset HEADLONG_IDENTITY_USER HEADLONG_OPERATOR_NAME
    # shellcheck disable=SC1090  # generated copy of the installer under test
    source "$WORK/install.lib"
    _docker_forward_args | tr '\0' ' '
)
case "$none" in
    *API_KEY*|*AWS_ACCESS_KEY_ID*|*AWS_SECRET_ACCESS_KEY*|*AWS_PROFILE*) bad "no key is forwarded when none is set" "got: $none" ;;
    *)         ok  "no key is forwarded when none is set" ;;
esac

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
