# OpenAI Responses lifecycle operations

Status: implemented on the 24601/headlong fork (2026-09-05), stacked on the
Responses completion protocol (design/responses-api.md, upstream PR #101).
Each section below names its tests and any place the build departed from the
sketch. Nothing here is proposed upstream until that PR lands and the pieces
have run for a while. Landed as fork PRs #2 (bin/responses), #3 (background),
#4 (WebSocket), #5 (compaction) and #6 (Conversations) on the integration
branch `feat/responses-lifecycle` (PR #1).

The PR #1 hardening contracts below distinguish local recovery safeguards from
server guarantees. The HTTP completion changes are specified under
**Background responses**; the Conversation,
compaction, lifecycle CLI, and WebSocket descriptions reflect the current
implementation.

## Why a second surface

`bin/llm` is the completion boundary: one request, one terminal object. The
Responses API also has server-side state with its own life: a stored response
can be fetched, cancelled, deleted, and its input items listed; a Conversation
is a durable container that never expires; a background response runs after
the request returns; compaction rewrites a long window into an opaque item;
WebSocket mode keeps a connection open across turns. Those are operations on
state, not completions, so they get their own tool, `bin/responses`, and the
completion path learns only what it needs to cooperate with them.

Provider scope is native OpenAI first. OpenRouter's `/responses` is stateless
(no retrieve, cancel, delete, conversations); `bin/responses` does not special
case it, the endpoint's own 404 is the answer. `openai-compatible` endpoints
get the same paths relative to their configured base.

## bin/responses

Status: implemented (`tests/test_responses_cli.sh`). Two notes: each
subcommand rejects flags that belong to another subcommand (exit 2) rather
than ignoring them, and `include` arrays are sent as repeated `include[]=`
query parameters, the encoding the official SDKs use.

One bash tool, curl and jq only, sharing `bin/llm`'s environment: the vendor
keys, `LLM_PROVIDER` / `--provider` (default `openai`), `LLM_API_URL` (when set
its `/responses` suffix is stripped and the rest is the API base), and the net
guards `LLM_CONNECT_TIMEOUT` and `LLM_MAX_TIME`. Stdout is the machine channel:
the API object exactly as returned, one JSON document per command (compact,
`--pretty` for humans). A non-2xx reply prints `responses: error: <message>` on
stderr, writes nothing to stdout, and exits 1. Exit 2 is a usage error.

```
responses get ID [--include V]... [--stream] [--starting-after N]
responses cancel ID
responses delete ID
responses input-items ID [--after ID] [--limit N] [--order asc|desc] [--include V]... [--all]
responses compact --model M (--input-file F | --previous-response-id ID) [--instructions S] [--body-file F]
responses conversations create [--items-file F] [--metadata JSON]
responses conversations get CID
responses conversations update CID --metadata JSON
responses conversations delete CID
responses conversations items CID [--after ID] [--limit N] [--order asc|desc] [--include V]... [--all]
responses conversations add CID --items-file F [--include V]...
responses conversations item CID ITEM_ID
responses conversations remove CID ITEM_ID
```

Paths and verbs, from the API reference (verify against
developers.openai.com/api/docs/api-reference before pinning a test):

| command | request |
|---|---|
| get | `GET /responses/{id}` with `include[]`, `stream`, `starting_after` |
| cancel | `POST /responses/{id}/cancel` (background responses only; idempotent) |
| delete | `DELETE /responses/{id}` returns `{id, object:"response", deleted:true}` |
| input-items | `GET /responses/{id}/input_items` with `after`, `limit` (1-100, default 20), `order` (default desc), `include[]`; list object with `data`, `first_id`, `last_id`, `has_more` |
| compact | `POST /responses/compact` with `model`, `input` or `previous_response_id`, `instructions`; the reply's `output` is the canonical next window, preserved as-is |
| conversations create | `POST /conversations` with `items` (max 20), `metadata` |
| conversations get / update / delete | `GET`, `POST` (`metadata` only), `DELETE /conversations/{cid}` |
| conversations items / add / item / remove | `GET`, `POST` (`items`, max 20), `GET`, `DELETE` under `/conversations/{cid}/items` |

`--all` follows `has_more` with `after=<last id>` and prints one merged list
object only after verified exhaustion. Malformed pages, empty continuing pages,
cursor cycles, duplicate item IDs, or continuing past 500 pages fail rather
than claiming `has_more:false`. List transfers and the aggregate are bounded
to 64 MiB. This is not a snapshot guarantee during concurrent server changes.
Temporary auth, body, and response files live in one private command directory,
removed on normal/error exit and handled signals after the owned curl child is
stopped and reaped; SIGKILL or power loss cannot run that cleanup.
`--stream` on `get` prints each SSE `data:` payload as one JSON line
and exits 0 only after a terminal event (`response.completed`, `.incomplete`,
`.failed`, `.cancelled`); this is the resume channel for background streams.

Tests (`tests/test_responses_cli.sh`): a curl stub records method, URL, and
body; pin each path, query encoding of repeated `include`, `--all` pagination,
the error contract, and that keys never appear on argv. Runs under bash 3.2.

## Background responses (bin/llm)

Status: background support is implemented; the following HTTP hardening
contract is being integrated and still needs verification against the final
`bin/llm` changes (`tests/test_llm_responses_background.sh`).

Opt in with `LLM_RESPONSES_BACKGROUND=1`, or `background: true` in the body
file (no longer rejected); `0` forces foreground over the body file. `store`
is left to the caller; the API keeps the data it needs for polling either way.
The retrieve and cancel URLs are derived from the create URL by stripping its
`/responses` suffix, so the create endpoint must end that way.

- Streaming create: `background: true, stream: true`. The handler remembers
  the response id from the first event carrying `.response.id` and the
  `sequence_number` of every event. If the stream drops before a terminal
  event (curl error, or EOF without one), llm does not re-create: it resumes
  with `GET /responses/{id}?stream=true&starting_after=N`, up to `LLM_RETRIES`
  times, and nothing already emitted is emitted twice. A drop before an ID is
  known is an unknown create outcome, not permission to create again.
- Non-streaming create: the reply is `queued` or `in_progress`; llm polls
  `GET /responses/{id}` every `LLM_RESPONSES_POLL_INTERVAL` seconds (default 2,
  backing off to 10) until a terminal status or the deadline, then treats the
  object exactly like an immediate buffered or streamed terminal reply. All
  three paths share terminal validation: failed/cancelled states, embedded
  errors, malformed envelopes, and unknown statuses cannot become success.
- Retry and deadline: Responses CREATE is not automatically retried after an
  uncertain failure, even if nothing reached stdout. Unknown outcomes fail
  with `error.code=outcome_unknown`; Chat Completions retry policy is unchanged.
  One absolute `LLM_MAX_TIME` deadline starts before create and covers polling,
  reconnects, network waits, and backoff; waits are clamped to remaining time
  and late completion is not accepted as timely success.
- Cancel: while a background response is in flight, SIGINT, SIGTERM, and the
  `LLM_MAX_TIME` deadline POST `/responses/{id}/cancel` best effort, with up to
  five additional seconds beyond the operation budget. A cancellation request
  does not guarantee the job stopped. Only a terminal response for the same
  response ID confirms settlement; only its `cancelled` status confirms
  cancellation (a concurrent completion may win). Otherwise the nonzero exit
  retains an unknown-outcome sidecar and the known ID for reconciliation.
  `cancelled` is terminal: warning on stderr, sidecar written, exit non-zero,
  and no fresh generation. Text already streamed cannot be withdrawn.
- shellm: `SHELLM_RESPONSES_BACKGROUND=1` passes through. Its continuation
  contract is unchanged because a terminal object still arrives.

Tests extend `tests/test_llm_responses.sh`: queued then in_progress then
completed by polling; a dropped stream resumed with `starting_after` and no
duplicated text; TERM during a job records a cancel POST.

## Conversations

Status: implemented (`tests/test_llm_responses.sh`,
`tests/test_shellm_responses_continuation.sh`). One addition to the sketch
below: the WebSocket adapter puts `conversation` on its `response.create` too,
so the choice of transport does not change which state a run carries.

`bin/llm` accepts `conversation` from the body file, or
`LLM_RESPONSES_CONVERSATION=<conv id>`, when `LLM_PREVIOUS_RESPONSE_ID` is
empty; both at once is still an error, because the API rejects the pair.

`bin/shellm`: `SHELLM_RESPONSES_CONVERSATION=new|conv_...` chooses server-held
state instead of the process-local chain. `new` creates a conversation at run
start (`responses conversations create`). The id is recorded in the
`shellm-run` header row as `conversation`; unlike response ids, this is
durable on purpose (Conversations do not expire automatically). `--resume` or
`--traj` reuses the latest header's ID when the setting is `new` or empty/unset;
a different literal ID intentionally redirects the run. Each call sends only
the new items with `conversation` set and
never `previous_response_id`; the replay chain is not kept. A missing or
rejected conversation fails closed with a clear error: the operator chose
durable server state, so there is nothing safe to fall back to.

Sent trajectory step IDs are checkpointed in
`$SHELLM_TRAJ_DIR/.responses-conversations/<conv_id>.json` (under the effective
trajectory directory). These versioned files are atomically replaced at mode
0600 in a mode-0700 directory, bound to the trajectory path, Conversation,
underlying provider, and endpoint. A local exclusive `mkdir` lock is held for
the whole run. Before dispatch the checkpoint becomes `in_flight`; only a
validated successful terminal response advances the sent-step acknowledgement
and returns it to `ready`. Resume restores that acknowledgement, preserving
genuinely unsent execution output rather than resending historical rows.

An in-flight/invalid/mismatched checkpoint, missing acknowledgement for an
already-recorded Conversation, or an existing lock fails closed. Locks are
never automatically stolen, including stale locks after crashes. Reconcile
server state and local ownership before reuse; deleting a lock alone does not
resolve ambiguous delivery. This is local atomic replacement and exclusive
ownership, not fsync-backed power-loss durability, distributed coordination,
or an exactly-once server-delivery guarantee. A new/different Conversation
without local history starts with an empty acknowledgement, not inferred server
acknowledgements. Body-file Conversations are rejected by shellm before any
request; use `SHELLM_RESPONSES_CONVERSATION`. Generated child calls and summaries
do not inherit the parent's Conversation.

Tests: llm rejects the pair and sends `conversation` alone; shellm creates on
`new`, carries the id on every delta, records it in the header, reuses it on
resume, and dies cleanly on a rejected conversation.

## Compaction

Status: implemented (`tests/test_llm_responses.sh`,
`tests/test_shellm_responses_continuation.sh`). The compact reply's window is
its `output` array, passed on as is. A failed or invalid standalone compact
reply warns, keeps the chain, and disables standalone upkeep for that run.

- `bin/llm`: `LLM_RESPONSES_COMPACT_THRESHOLD=N` adds
  `context_management: [{type: "compaction", compact_threshold: N}]` to the
  create body (owned when the variable is set, otherwise the body file's value
  stands). Server-side compaction then happens inside a normal turn.
- `bin/shellm`: `SHELLM_RESPONSES_COMPACT_THRESHOLD=N` (tokens) opts into upkeep;
  it is a trigger, not a hard context-size limit. Choose
  `SHELLM_RESPONSES_COMPACT_MODE=auto|server|standalone`. `auto` selects server
  compaction for the native OpenAI provider at `api.openai.com` (or its default
  URL), including input-array replay with `store=false`; other configurations
  select standalone. Retention and continuation do not determine compaction
  capability. Explicit `server` declares that the chosen endpoint supports
  `context_management`; it passes the threshold through to llm even in replay.
- `standalone` with a threshold forces replay. After a terminal response whose
  `usage.input_tokens` reaches N, shellm calls `responses compact` with the
  underlying provider (not the WebSocket adapter), model, current instructions,
  and replay chain, then adopts the returned `output` array without pruning or
  reordering it. Endpoint support is not guaranteed merely by selecting auto.
  Conversation mode plus a threshold requires server compaction.
- A server-produced compaction item prunes replay to the **newest** marker.
  That turn does not also trigger standalone compaction from pre-compaction
  usage. This pruning rule does not apply to standalone compact output.

Tests: the threshold fires once per crossing, the replay file shrinks to the
compacted window and later requests begin with the compaction item; llm adds
`context_management` only when asked.

## WebSocket mode

Status: implemented. Endpoint and credentials follow the underlying provider:
`openai` uses `OPENAI_API_KEY`, `openai-compatible` uses `LLM_API_KEY` and an
explicit URL. HTTP(S) URLs become WS(S) without changing path or query. Shellm
uses its resolved `SHELLM_API_URL` / `LLM_API_URL` for both lifecycle operations
and completions and rejects `RESPONSES_WS_URL`; the standalone adapter permits
that override. Native OpenAI defaults to `wss://api.openai.com/v1/responses`.
Unsupported providers, OpenRouter routing/privacy settings, and background,
`provider`, or `stream_options` body settings are rejected rather than silently
discarded. `store` passes through unchanged; instructions, previous-response
ID removal, and server-compaction thresholds follow the HTTP field ownership.

An adapter, not core: `tools/responses-ws`, a Python script (`uv run`, PEP 723
metadata, Python >=3.10 and `websockets==17.1`), following the adapter contract in
design/providers.md plus the Responses environment (`LLM_RESPONSE_FILE`,
`LLM_PREVIOUS_RESPONSE_ID`, `LLM_RESPONSES_BODY_FILE`). `bin/llm` allows
`--provider adapter` with `LLM_API_FORMAT=responses` and adds `--api-format
responses` to the adapter argv so the adapter knows the stdin JSON is typed
Responses input. The adapter's output contract is llm's Responses contract:
text on stdout as it streams, reasoning summaries on stderr, the terminal
object in the sidecar, usage in `LLM_USAGE_FILE`, exit non-zero on failure.

Two roles in one file. `serve` holds one connection to
the resolved endpoint (rotating idle connections older than 55 minutes), listens
on a unix socket, multiplexes callers onto `stream_id` lanes (16 in flight, 32
named per connection), and exits when idle for `RESPONSES_WS_IDLE` minutes or
told `stop`. The default role is the per-call adapter: when
`RESPONSES_WS_SOCKET` is set it forwards through that broker; missing or failed
brokers fail the call with no blind one-shot fallback. Only an unset socket
selects one-shot mode. shellm's `SHELLM_API_TRANSPORT=websocket` starts
the broker at run start (socket in rundir), points llm at the adapter, and
stops it at cleanup. Continuation via `previous_response_id` works through the
connection-local cache even with `store: false` for direct adapter callers;
shellm explicitly uses replay for `store:false`. A
`previous_response_not_found` error takes the existing replay fallback.

The broker owns lanes within a connection generation and checks response IDs.
Abandoning an unsettled request retires the connection instead of recycling its
lane while old events can still arrive. Other unsettled callers on that
connection may fail with `error.code=outcome_unknown`; retirement does not
confirm server cancellation. A later caller may open a new connection, but
abandoned creates are not replayed. Connection-scoped errors are fanned out.
Local JSON frames are bounded at 16 MiB of UTF-8 bytes (excluding the newline),
including framing overhead; upstream messages are also bounded at 16 MiB.
Per-lane queues allow at most 64 events / 16 MiB, local admission at most 32
clients, and initial local request reads and writes are bounded at 30 seconds. Oversize frames
and slow consumers fail rather than grow memory without bound. These are
transport bounds, not the HTTP whole-operation deadline contract.

The installer includes `responses-ws` in copy and symlink installs; uninstall
removes it. Selecting WebSocket mode requires `uv`; HTTPS does not.

Tests: a fake WebSocket server in the test itself (same library) checks the
`response.create` payload, streamed text order, the sidecar, an error event,
and broker multiplexing of two concurrent callers. The fault suite covers
abandonment, cross-talk, large frames, bounded queues, connection retirement,
and transport parity. Missing `uv` fails the test rather than silently leaving
the transport untested.

## Line budget

`cloc bin/ thinkers/` is capped by CI. The hardened fork stands near 11,900
code lines, under the unchanged fork cap of 12,000. Upstream's cap of 11,000
is untouched by PR #101. Python transport, tests and documentation are outside
that core count, not free complexity; they have their own verification.
