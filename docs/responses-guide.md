# Using Responses in Headlong

Use Responses when a plain string completion is not enough: typed tool or
multimodal output, recoverable long-running inference, a resumable conversation,
or explicit control over a growing context window. These features remain
optional. Chat Completions and the ordinary shellm loop still work without them.

For the framework itself, start with [Operating Headlong](operating-headlong.md).
For every flag, use `llm --help`, `responses --help`, and `shellm --help`;
[the engine reference](shellm.md) and the
[lifecycle contract](../design/responses-lifecycle.md) explain implementation details.
Agents should load `skills show operating-headlong-responses`.

## Choose the smallest surface

| Need and intent | Use | Ownership and limitation |
|---|---|---|
| Classify, extract, draft, or inspect typed output without executing shell commands | `LLM_API_FORMAT=responses llm` | One completion; your caller validates and uses the result |
| Let a model investigate files and execute Bash iteratively | `SHELLM_API_FORMAT=responses shellm` | A code-executing loop, not a passive completion API; use a sandbox |
| Wait for slow inference without recreating it after a connection drop | Background `llm` over HTTPS | llm owns the wait/cancel attempt; your application owns durable jobs |
| Recover, inspect, cancel, or delete remote objects | `responses` | Explicit lifecycle operations; use the original provider/account/endpoint |
| Resume an interactive shellm session without resending old turns | Conversation mode | Server history plus local sent-step checkpoints; one local owner |
| Reduce connection setup across repeated calls | WebSocket adapter/broker | Optional Python/uv transport; not an independent scheduler |
| Control repeated context growth | Server or standalone compaction | Context optimization, not a factual database or deletion guarantee |

Headlong does **not** supply application authorization, tenant isolation,
exactly-once publication, durable task leases, or a business event store. A
service can use `llm` as a subordinate worker while keeping those decisions in
one application-owned coordinator. Treat model output and uploaded tool/document
content as untrusted data; metadata is not authority.

## Before making a request

- Use a dedicated, spend-capped key. Native OpenAI reads `OPENAI_API_KEY`;
  `openai-compatible` reads `LLM_API_KEY` with an explicit `LLM_API_URL`.
  Never put a key in a command argument, prompt, committed file, or example.
- Check `.env` files as well as the process environment. Explicit environment
  settings win; `llm` also reads the working directory and state-home `.env`.
  Isolate HOME/state and working directory for a service worker.
- Choose a model the endpoint supports. Examples use `gpt-5.4-mini`; this is
  illustrative, not a claim that every account or compatible provider has it.
- Keep stdout, stderr, and the JSON sidecar separate. A partial streamed answer
  is not a successful operation. Protect all three as potentially sensitive.
- Set `LLM_MAX_TIME` and an output cap. These are latency/token controls, not
  a provider dollar-spend guarantee. Hosted tools may have additional charges.

### Capability and configuration matrix

| Combination | Behavior |
|---|---|
| Native OpenAI + HTTPS | Completion, continuation, background and lifecycle paths; check account/model availability |
| OpenRouter + HTTPS | Responses completion starts in exact replay; lifecycle paths are not promised |
| Other OpenAI-compatible endpoint + HTTPS | Exact configured URL, compatible key; lifecycle/compaction support is endpoint-specific |
| WebSocket | Only underlying `openai` or `openai-compatible`; uv and pinned `websockets==17.1` required |
| Background + WebSocket | Rejected before dispatch; explicit background `0` overrides body `true` just as on HTTPS |
| Conversation + previous response ID | Rejected; choose one state mechanism |
| Shellm body-file Conversation | Rejected at startup; use `SHELLM_RESPONSES_CONVERSATION` |
| `store:false` + shellm | Exact input/output-item replay; not a blanket no-retention promise |
| Native server compaction + `store:false` | Supported; compaction and retention are independent choices |
| Conversation + compaction threshold | Requires server compaction support, not standalone compaction |

An HTTP(S) WebSocket endpoint is translated to WS(S) without changing its host,
path or query. Shellm rejects a separate `RESPONSES_WS_URL` to prevent completion
and lifecycle calls from silently targeting different servers. OpenRouter
privacy/routing options are rejected by the WebSocket adapter, not ignored.

## 1. A completion as a service worker

From a checkout, put `bin/` and `tools/` on PATH. With an installed copy they are
already in the installation prefix. The following commands **spend inference
credits when run**; no live inference is needed to read or test this guide.

```bash
umask 077
mkdir -p private-input
printf '%s\n' '[{"role":"user","content":"Summarize these synthetic observations: A passed; B failed."}]' \
  > private-input/input.json
printf '%s\n' '{"store":false}' > private-input/body.json

LLM_MODEL=gpt-5.4-mini LLM_MAX_TIME=60 LLM_MAX_TOKENS=800 \
  bash docs/examples/responses-request.sh private-run-001 \
  private-input/input.json private-input/body.json
```

The [executable example](examples/responses-request.sh) requires a new output
directory and retains `response.json`, `stdout.txt`, `stderr.txt`, and
`outcome.json`. It never retries a create or executes generated text. Exit 0
requires a completed terminal object; incomplete is retained but not accepted
as a complete application answer. Preserve failures for reconciliation, then
apply your own retention policy. Do not put these directories in a public repo.

Other typed input items can go into the JSON input array unchanged: input images
or files, function-call outputs, and opaque reasoning items. Put additional
supported create fields in the body file—for example `tools`, `include`,
`text.format`, or `metadata`. llm owns `model`, `input`, `instructions`,
`stream`, `max_output_tokens`, and `previous_response_id`; stale body values
cannot override those controls. Supply instructions with `--system-prompt` in a
direct llm call. For large input, prefer `--messages-file` over JSON on argv.

For structured extraction, a body can request a schema:

```json
{"store":false,"text":{"format":{"type":"json_schema","name":"assessment","strict":true,"schema":{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}}}}
```

Still validate the returned JSON against the application's schema and policy.
Refusals, incomplete output, or tool-only results need explicit handling.
`llm` preserves function calls in the sidecar; it does not execute your function.
Shellm cannot dispatch Responses-native function calls without visible shellm
output and fails closed instead of treating them as another empty turn.

## 2. Long operations, interruption, and recovery

Use the same example with `LLM_RESPONSES_BACKGROUND=1 LLM_MAX_TIME=300` when a
provider supports background work. HTTPS streaming resumes a known response
using its last sequence number; `--no-stream` uses polling. Direct example:

```bash
LLM_API_FORMAT=responses LLM_RESPONSES_BACKGROUND=1 \
LLM_RESPONSE_FILE="$PWD/private-response.json" LLM_MAX_TIME=300 \
  llm --provider openai -m gpt-5.4-mini --no-stream --messages-file private-input/input.json
```

`LLM_RETRIES` bounds GET retries/resumes, **not CREATE retries**. A lost create
acknowledgement may mean the provider is already working. Do not wrap llm in a
generic retry loop. `error.code=outcome_unknown` means reconcile; it does not
mean “nothing happened.” Without a response ID, Headlong cannot discover the
accepted operation for you. Keep your own operation/attempt correlation and
provider request tracing; tracing alone does not make a create idempotent.

One deadline covers create, polls, resumes and backoff. SIGINT/SIGTERM, deadline
expiry, exhausted resumes and an intentional stream cut attempt cancellation
when a background ID is known. Cancellation gets up to five additional seconds.
Only a terminal object for that ID confirms settlement. `completed` may win the
race; only `cancelled` confirms cancellation. A failed cancel preserves the ID
and unknown outcome, rather than asserting the job stopped.

```bash
# Use the same provider, endpoint and account that created the object.
responses get resp_example --include reasoning.encrypted_content
responses input-items resp_example --all --order asc
responses get resp_example --stream --starting-after 42
# Mutation: run only when cancellation is intended and authorized.
responses cancel resp_example
```

`responses get --stream` is an event-retrieval command: successful delivery of
a **failed or cancelled** terminal event still exits 0. This differs from llm's
completion-success contract. Inspect the event, not just the retrieval exit code.
`--all` emits a merged list only after verified exhaustion; malformed or cyclic
pagination, duplicates, 500 continuing pages, or a 64 MiB bound fail visibly.
It cannot promise a consistent snapshot during concurrent edits.

Deleting a Response or Conversation is explicit (`responses delete ID`,
`responses conversations delete CID`). Do not make deletion a blind cleanup
trap: it can remove recovery evidence or shared history, and is not proof that
all provider retention or billing has ended.

## 3. Stateful sessions and shellm continuation

Ordinary Responses shellm uses a previous response ID and retains exact typed
replay in its private run directory. OpenRouter and explicit `store:false`
start with replay. A structured pre-generation continuation rejection can
trigger one replay fallback; unknown outcomes and terminal failures cannot.
After exit these process-local IDs/replay items disappear; a new process rebuilds
from the durable trajectory. That is not exact typed replay across restarts.

Conversation mode is for a persistent session with one owner:

```bash
SHELLM_API_FORMAT=responses SHELLM_MODEL=gpt-5.4-mini \
SHELLM_RESPONSES_CONVERSATION=new shellm "Investigate the test failure in this sandbox"
# In the same trajectory context, after the first run has stopped:
SHELLM_API_FORMAT=responses SHELLM_MODEL=gpt-5.4-mini \
  shellm --resume "Continue with the next test"
```

These commands execute model-generated Bash: do not run them unsandboxed on
sensitive work. Set a concrete `SHELLM_TRAJ_DIR`/trajectory when multiple sessions
exist; do not guess which run `--resume` will select. `new` or empty/unset reuses
the latest resumed header's Conversation; a different literal `conv_...` starts
a different history window. To start fresh, start a new trajectory rather than
expecting `new` on an old trajectory to discard its Conversation.

Acknowledgements live at
`$SHELLM_TRAJ_DIR/.responses-conversations/<conv_id>.json`, bound to canonical
trajectory, provider and endpoint. The directory is 0700, files 0600, replacement
atomic, and a local exclusive lock lasts for the whole run. That lock is keyed
by provider, effective endpoint, and Conversation ID under
`$HEADLONG_HOME/run/responses-conversations/` (or the selected legacy state
home), independent of the trajectory root. Before dispatch the checkpoint
becomes `in_flight`; terminal validation advances it to `ready`. A failed
Conversation context render stops before dispatch and leaves the ready
acknowledgement unchanged.
Resume sends genuinely unsent rows, not old prompts and outputs a second time.
Generated child calls and summaries do not inherit the parent's Conversation.

On an ambiguous checkpoint, missing acknowledgement, mismatched binding, or stale
lock: stop dispatch, inspect remote items and local trajectory, and reconcile
ownership/delivery. There is no automatic repair command and no safe “delete the
lock and retry” rule. Without proof, use a new explicit session and retain the
old evidence. Atomic rename is not fsync-backed power-loss durability, a
distributed lock, or coordination with other API clients sharing the Conversation.

## 4. Low-latency repeated calls

```bash
SHELLM_API_FORMAT=responses SHELLM_API_TRANSPORT=websocket \
SHELLM_MODEL=gpt-5.4-mini shellm "Inspect this sandbox and run its targeted tests"
```

Shellm owns a private broker socket and one provider connection. Direct llm
callers can run `responses-ws serve --socket /private/path/broker.sock`, then set
`LLM_PROVIDER=adapter`, `LLM_ADAPTER` to the executable path,
`RESPONSES_WS_PROVIDER=openai` and `RESPONSES_WS_SOCKET` for each llm call. Use a
supervisor to own that broker and `responses-ws stop --socket ...` to stop it.
With no socket configured, the adapter is one-shot. A configured dead broker
does **not** fall back to an independent create.

Limits: 16 in-flight responses, 32 admitted local clients, 32 reusable stream
names per connection; 16 MiB UTF-8 JSON frames; 64 events/16 MiB per-lane queues.
Idle connections rotate after 55 minutes. These are transport limits, not a
claim of unlimited parallelism or a durable queue. Slow consumers and oversize
frames fail. If a caller disappears with an unsettled request, the connection
is retired so late events cannot become someone else's answer. Other unsettled
callers may also fail with unknown outcomes. Closure is not server cancellation.

## 5. Context growth and evidence

Set `SHELLM_RESPONSES_COMPACT_THRESHOLD` below the endpoint's context limit,
reserving room for the next tool/document result and model output/reasoning.
The threshold is a trigger, not a hard ceiling; input arriving in one large turn
can overflow before upkeep. There is no universal threshold across models.

`SHELLM_RESPONSES_COMPACT_MODE=auto` chooses server compaction for native OpenAI
and standalone for other endpoints. `server` explicitly declares support for
`context_management`; `standalone` forces replay and calls `/responses/compact`.
Server output prunes replay to its **newest usable** compaction marker. A marker
without non-empty opaque `encrypted_content` cannot prune or enter the replay.
Standalone output replaces the window **as-is**, including items before any
marker, after the same payload check. A failed standalone compact preserves the
chain and disables upkeep for that run.
Standalone upkeep only receives the completion's remaining time budget; its
reported usage enters the shared ledger as `operation:"responses.compact"`.

```bash
SHELLM_API_FORMAT=responses SHELLM_MODEL=gpt-5.4-mini \
SHELLM_RESPONSES_COMPACT_MODE=server \
SHELLM_RESPONSES_COMPACT_THRESHOLD=20000 \
  shellm "Analyze these synthetic logs in the sandbox"
```

Keep authoritative constraints, provenance and application decisions outside
opaque compaction. Test recall of late-relevant constraints and superseded
instructions—not only token savings. `store:false` does not imply Zero Data
Retention; background execution can require temporary provider storage.

## What changed, and how it is checked

PR #1 hardening fixes abandoned WebSocket ownership, realistic frame sizes,
provider/body parity, connection errors, age rotation, and drain-before-reuse
rotation after each generation's 32 unique stream names; secret temp cleanup;
unknown-create and terminal-state handling; absolute deadlines and truthful
cancellation; Conversation resume and body-mode validation; repeated compaction,
provider preservation and accounting; pagination completeness; and copy installs.

Run `tests/run-all.sh responses` for focused protocol tests and
`tests/run-all.sh` for the full harness. The executable example is covered by
`tests/test_responses_examples.sh`; packaging by `tests/test_responses_install.sh`
and `tests/smoke_install.sh`. Fault suites use curl stubs or local servers and
synthetic data, not paid inference. A green hermetic suite is not a live-provider
conformance certificate. Test your exact provider/model/policy combination with
synthetic inputs and an explicitly approved spend bound before production use.
