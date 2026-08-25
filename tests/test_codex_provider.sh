#!/usr/bin/env bash
# Verify the Codex provider speaks the app-server JSONL protocol without an API key.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/codex" <<'MOCK'
#!/usr/bin/env python3
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    if request.get("id") == 1:
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif request.get("id") == 2:
        print(json.dumps({"id": 2, "result": {"thread": {"id": "test-thread"}}}), flush=True)
    elif request.get("id") == 3:
        print(json.dumps({"method": "item/agentMessage/delta", "params": {"delta": "subscription reply"}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}), flush=True)
MOCK
chmod +x "$WORK/codex"

export HEADLONG_HOME="$WORK/home"
export CODEX_APP_SERVER_BIN="$WORK/codex"
mkdir -p "$HEADLONG_HOME"

output=$(env -u OPENAI_API_KEY "$REPO/bin/llm" --provider codex -m gpt-5.6-luna 'test prompt')
test "$output" = 'subscription reply' || { echo "unexpected output: $output" >&2; exit 1; }
echo 'ok   codex provider uses app-server and does not require OPENAI_API_KEY'
